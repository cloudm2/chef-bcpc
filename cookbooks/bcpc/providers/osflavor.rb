#
# Cookbook Name:: bcpc
# Provider:: osflavor
#
# Copyright 2013, Bloomberg Finance L.P.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
require 'open3'
require 'json'

def whyrun_supported?
  true
end

def openstack_cli
  args =  ["openstack", 
      "--os-tenant-name", node['bcpc']['admin_tenant'], 
      "--os-username", get_config('keystone-admin-user'),
      "--os-auth-url", "#{node['bcpc']['protocol']['keystone']}://openstack.#{node['bcpc']['cluster_domain']}:5000/v2.0/",
      "--os-region-name", node['bcpc']['region_name'],
      "--os-password" , get_config('keystone-admin-password')]
end

def nova_cli
  # Note the amazing lack of consistency between openstack CLI and nova CLI when it 
  # comes to args e.g. "--os-user-name" vs "--os-username".  
  args =  ["nova", 
      "--os-project-name", node['bcpc']['admin_tenant'], 
      "--os-user-name", get_config('keystone-admin-user'),
      "--os-auth-url", "#{node['bcpc']['protocol']['keystone']}://openstack.#{node['bcpc']['cluster_domain']}:5000/v2.0/",
      "--os-region-name", node['bcpc']['region_name'],
      "--os-password" , get_config('keystone-admin-password')]
end 

action :create do
  args = openstack_cli
  stdout, stderr, status = Open3.capture3(*(args+ ["flavor", "show", @new_resource.name, "-f", "json"] ))
  if not status.success? 
    converge_by("Creating #{new_resource.name}") do
      ispub = @new_resource.is_public ? "--public" : "--private"
      stdout, status = Open3.capture2( *(args + ["flavor", "create", @new_resource.name , "-f", "json",  
                                                 "--ram=#{@new_resource.memory_mb}", 
                                                 "--disk=#{@new_resource.disk_gb}",
                                                 "--ephemeral=#{@new_resource.ephemeral_gb}",
                                                 "--swap=#{@new_resource.swap_gb}",
                                                 "--vcpus=#{@new_resource.vcpus}", 
                                                 "--id=#{@new_resource.flavor_id}",
                                                 "#{ispub}"]
                                        ) )
      Chef::Log.error "Failed to create to flavor" unless status.success?
    end
  end

  # The openstack CLI doesn't have a way today (kilo) to get the extra_specs
  # so fall back to nova CLI. 
  stdout, stderr, status = Open3.capture3(*(nova_cli + ["flavor-show",  @new_resource.name] ))
  if not status.success?
    Chef::Log.error "Failed to get flavor info"  
    raise("Unable to get flavor info.")
  end
  
  line = stdout.split("\n").select { |x| x.include? " extra_specs "}
  if line.nil? or line.empty?
    raise("No extra_specs line in 'nova flavor-show'")
  end 
  
  current_specs = JSON.parse(line[0].split("|")[2])
  new_specs = current_specs.clone 
  @new_resource.extra_specs.each { |k, v| new_specs[k.to_s] = v.to_s }
  
  if current_specs != new_specs
    converge_by("Update flavor extra_specs") do
      kvp = new_specs.collect { |k,v| k + "=" + v}
      stdout, status = Open3.capture2(*(nova_cli + ["flavor-key",  @new_resource.name, "set"] + kvp ))
      Chef::Log.error "Failed to update flavor extra_specs" unless status.success?
    end
  end
end

action :delete do
  stdout, stderr, status = Open3.capture3(*(openstack_cli + 
                                            ["flavor", "show", @new_resource.name]))
  if status.success? 
    converge_by("deleting #{new_resource.name}") do
      stdout, status = Open3.capture2(*(openstack_cli + 
                                        ["flavor", "delete", @new_resource.name ] ))
      Chef::Log.error "Failed to delete to flavor" unless status.success?
    end
  end
end

