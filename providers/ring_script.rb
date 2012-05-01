#
# Copyright 2012, Rackspace Hosting
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: Ron Pedde <ron.pedde@rackspace.com>
#

require "pp"

def generate_script
  # need to load and parse the existing rings.
  ports = { "object" => "6000", "container" => "6001", "account" => "6002" }

  ring_path = @new_resource.ring_path
  ring_data = { :raw => {}, :parsed => {}, :in_use => {} }
  disk_data = {}
  dirty_cluster_reasons = []

  [ "account", "container", "object" ].each do |which|
    ring_data[:raw][which] = nil

    if ::File.exist?("#{ring_path}/#{which}.builder")
      IO.popen("swift-ring-builder #{ring_path}/#{which}.builder") do |pipe|
        ring_data[:raw][which] = pipe.readlines
        # Chef::Log.info("#{ which.capitalize } Ring data: #{ring_data[:raw][which]}")
        ring_data[:parsed][which] = parse_ring_output(ring_data[:raw][which])

        node["swift"]["state"] ||= {}
        node["swift"]["state"]["ring"] ||= {}
        node["swift"]["state"]["ring"][which] = ring_data[:parsed][which]
      end
    else
      Chef::Log.info("#{which.capitalize} ring builder files do not exist")
    end

    # collect all the ring data, and note what disks are in use.  All I really
    # need is a hash of device and id

    ring_data[:in_use][which] ||= {}
    if ring_data[:parsed][which][:hosts]
      ring_data[:parsed][which][:hosts].each do |ip, dev|
        dev.each do |dev_id, devhash|
          ring_data[:in_use][which].store(devhash[:device], devhash[:id])
        end
      end
    end

    # Chef::Log.info("#{PP.pp(ring_data[:in_use][which],dump='')}")

    # figure out what's present in the cluster
    disk_data[which] = {}
    disk_state, something, whatever = Chef::Search::Query.new.search(:node,"chef_environment:#{node.chef_environment} AND roles:swift-#{which}-server")

    disk_state.each do |swiftnode|
      if swiftnode[:swift][:state] and swiftnode[:swift][:state][:devs]
        swiftnode[:swift][:state][:devs].each do |k,v|
          disk_data[which][v[:ip]] = disk_data[which][v[:ip]] || {}
          disk_data[which][v[:ip]][k] = {}
          v.keys.each { |x| disk_data[which][v[:ip]][k].store(x,v[x]) }

          if swiftnode[:swift].has_key?("#{which}-zone")
            disk_data[which][v[:ip]][k]["zone"]=swiftnode[:swift]["#{which}-zone"]
          elsif swiftnode[:swift].has_key?("zone")
            disk_data[which][v[:ip]][k]["zone"]=swiftnode[:swift]["zone"]
          else
            raise "Node #{swiftnode[:hostname]} has no zone assigned"
          end

          # keep a running track of available disks
          disk_data[:available] ||= {}
          disk_data[:available][which] ||= {}
          disk_data[:available][which][v[:mountpoint]] = v[:ip]

          if not v[:mounted]
            dirty_cluster_reasons << "Disk #{v[:name]} (#{v[:uuid]}) is not mounted on host #{v[:ip]} (#{swiftnode[:hostname]})"
          end
        end
      end
    end
  end

  # Have the raw data, now bump it together and drop the script

  s = "#!/bin/bash\n\n# This script is automatically generated.\n"
  s << "# Running it will likely blow up your system if you don't review it carefully.\n"
  s << "# You have been warned.\n\n"
  s << "exit 0\n\n"

  # Chef::Log.info("#{PP.pp(disk_data, dump='')}")

  new_disks = {}
  missing_disks = {}

  [ "account", "container", "object" ].each do |which|
    # remove available disks that are already in the ring
    new_disks[which] = disk_data[:available][which].reject{ |k,v| ring_data[:in_use][which].has_key?(k) }

    # find all in-ring disks that are not in the cluster
    missing_disks[which] = ring_data[:in_use][which].reject{ |k,v| disk_data[:available][which].has_key?(k) }

    s << "\n# -- #{which.capitalize} Servers --\n\n"
    disk_data[which].keys.sort.each do |ip|
      s << "# #{ip}\n"
      disk_data[which][ip].keys.sort.each do |k|
        v = disk_data[which][ip][k]
        s << "#  " +  v.keys.sort.select{|x| ["ip", "device", "uuid"].include?(x)}.collect{|x| v[x] }.join(", ")
        if new_disks[which].has_key?(v["uuid"])
          s << " (NEW!)"
        end
        s << "\n"
      end
    end

    # for all those servers, check if they are already in the ring.  If not,
    # then we need to add them to the ring.  For those that *were* in the
    # ring, and are no longer in the ring, we need to delete those.

    must_rebalance = false

    s << "\n"

    # add the new disks
    disk_data[which].keys.sort.each do |ip|
      disk_data[which][ip].keys.sort.each do |uuid|
        v = disk_data[which][ip][uuid]
        if new_disks[which].has_key?(uuid)
          s << "swift-ring-builder #{ring_path}/#{which}.builder add z#{v['zone']}-#{v['ip']}:#{ports[which]}/#{v['mountpoint']} #{v['size']}\n"
          must_rebalance = true
        end
      end
    end

    # remove the disks -- sort to ensure consistent order
    missing_disks[which].keys.sort.each do |uuid|
      diskinfo = ring_data[:parsed][which][:hosts].select{|k,v| v.has_key?(uuid)}[0][1][uuid]
      description = Hash[diskinfo.select{|k,v| [:zone, :ip, :device].include?(k)}].collect{|k,v| "#{k}: #{v}" }.join(", ")
      s << "# #{description}\n"
      s << "swift-ring-builder #{ring_path}/#{which}.builder remove d#{missing_disks[which][uuid]}\n"
      must_rebalance = true
    end

    s << "\n"

    if(must_rebalance)
      s << "swift-ring-builder #{ring_path}/#{which}.builder rebalance\n\n\n"
    else
      s << "# #{which.capitalize} ring has no outstanding changes!\n\n"
    end
  end
  s
end

# Parse the raw output of swift-ring-builder
def parse_ring_output(ring_data)
  output = { :state => {} }

  ring_data.each do |line|
    if line =~ /build version ([0-9]+)/
      output[:state][:build_version] = $1
    elsif line =~ /^Devices:\s+id\s+zone\s+/
      next
    elsif line =~ /^\s+(\d+)\s+(\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s+(\S+)\s+([0-9.]+)\s+(\d+)\s+([-0-9.]+)\s*$/
      output[:hosts] ||= {}
      output[:hosts][$3] ||= {}

      output[:hosts][$3][$5] = {}

      output[:hosts][$3][$5][:id] = $1
      output[:hosts][$3][$5][:zone] = $2
      output[:hosts][$3][$5][:ip] = $3
      output[:hosts][$3][$5][:port] = $4
      output[:hosts][$3][$5][:device] = $5
      output[:hosts][$3][$5][:weight] = $6
      output[:hosts][$3][$5][:partitions] = $7
      output[:hosts][$3][$5][:balance] = $8
    elsif line =~ /(\d+) partitions, (\d+) replicas, (\d+) zones, (\d+) devices, ([\-0-9.]+) balance$/
      output[:state][:partitions] = $1
      output[:state][:replicas] = $2
      output[:state][:zones] = $3
      output[:state][:devices] = $4
      output[:state][:balance] = $5
    elsif line =~ /^The minimum number of hours before a partition can be reassigned is (\d+)$/
      output[:state][:min_part_hours] = $1
    else
      raise "Cannot parse ring builder output for #{line}"
    end
  end

  output
end

action :ensure_exists do
  Chef::Log.info("Ensuring #{new_resource.name}")
  new_resource.updated_by_last_action(false)
  s = generate_script

  script_file = File new_resource.name do
    owner new_resource.owner
    group new_resource.group
    mode new_resource.mode
    content s
  end

  script_file.run_action(:create)
  if script_file.updated_by_last_action?
    new_resource.updated_by_last_action(true)
  end
end
