#
# Cookbook Name:: bcpc
# Recipe:: keystone
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

include_recipe "bcpc::mysql-head"
include_recipe "bcpc::openstack"
include_recipe "bcpc::apache2"

ruby_block "initialize-keystone-config" do
    block do
        make_config('mysql-keystone-user', "keystone")
        make_config('mysql-keystone-password', secure_password)
        make_config('keystone-admin-token', secure_password)
        make_config('keystone-admin-user',  node["bcpc"]["ldap"]["admin_user"] || "admin")
        make_config('keystone-admin-password',node["bcpc"]["ldap"]["admin_pass"]  ||  secure_password)
        begin
            get_config('keystone-pki-certificate')
        rescue
            temp = %x[openssl req -new -x509 -passout pass:temp_passwd -newkey rsa:2048 -out /dev/stdout -keyout /dev/stdout -days 1095 -subj "/C=#{node['bcpc']['country']}/ST=#{node['bcpc']['state']}/L=#{node['bcpc']['location']}/O=#{node['bcpc']['organization']}/OU=#{node['bcpc']['region_name']}/CN=keystone.#{node['bcpc']['cluster_domain']}/emailAddress=#{node['bcpc']['admin_email']}"]
            make_config('keystone-pki-private-key', %x[echo "#{temp}" | openssl rsa -passin pass:temp_passwd -out /dev/stdout])
            make_config('keystone-pki-certificate', %x[echo "#{temp}" | openssl x509])
        end

    end
end

package 'keystone' do
    action :upgrade
    options "-o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
end

# needed to parse openstack json output
package 'jq' do
    action :upgrade
end

# do not run or try to start standalone keystone service since it is now served by WSGI
service "keystone" do
    action [:disable, :stop]
end

# standalone Keystone service has a window to start up in and create keystone.log with
# wrong permissions, so ensure it's owned by keystone:keystone
file "/var/log/keystone/keystone.log" do
  owner "keystone"
  group "keystone"
  notifies :restart, "service[apache2]", :immediately
end

template "/etc/keystone/keystone.conf" do
    source "keystone.conf.erb"
    owner "keystone"
    group "keystone"
    mode 00600
    variables(:servers => get_head_nodes)
    notifies :restart, "service[apache2]", :immediately
end

template "/etc/keystone/default_catalog.templates" do
    source "keystone-default_catalog.templates.erb"
    owner "keystone"
    group "keystone"
    mode 00644
    notifies :restart, "service[apache2]", :delayed
end

template "/etc/keystone/cert.pem" do
    source "keystone-cert.pem.erb"
    owner "keystone"
    group "keystone"
    mode 00644
    notifies :restart, "service[apache2]", :delayed
end

template "/etc/keystone/key.pem" do
    source "keystone-key.pem.erb"
    owner "keystone"
    group "keystone"
    mode 00600
    notifies :restart, "service[apache2]", :delayed
end

template "/etc/keystone/policy.json" do
    source "keystone-policy.json.erb"
    owner "keystone"
    group "keystone"
    mode 00600
    variables(:policy => JSON.pretty_generate(node['bcpc']['keystone']['policy']))
end

template "/root/adminrc" do
    source "adminrc.erb"
    owner "root"
    group "root"
    mode 00600
end

template "/root/keystonerc" do
    source "keystonerc.erb"
    owner "root"
    group "root"
    mode 00600
end

# configure WSGI

# /var/www created by apache2 package, /var/www/cgi-bin created in bcpc::apache2
wsgi_keystone_dir = "/var/www/cgi-bin/keystone"
directory wsgi_keystone_dir do
  action :create
  owner  "root"
  group  "root"
  mode   00755
end

%w{main admin}.each do |wsgi_link|
  link ::File.join(wsgi_keystone_dir, wsgi_link) do
    action :create
    to     "/usr/share/keystone/wsgi.py"
  end
end

template "/etc/apache2/sites-available/wsgi-keystone.conf" do
  source   "apache-wsgi-keystone.conf.erb"
  owner    "root"
  group    "root"
  mode     00644
  variables(
    :processes => node['bcpc']['keystone']['wsgi']['processes'],
    :threads   => node['bcpc']['keystone']['wsgi']['threads']
  )
  notifies :reload, "service[apache2]", :immediately
end

bash "a2ensite-enable-wsgi-keystone" do
  user     "root"
  code     "a2ensite wsgi-keystone"
  not_if   "test -r /etc/apache2/sites-enabled/wsgi-keystone.conf"
  notifies :reload, "service[apache2]", :immediately
end

ruby_block "keystone-database-creation" do
    block do
        %x[ export MYSQL_PWD=#{get_config('mysql-root-password')};
            mysql -uroot -e "CREATE DATABASE #{node['bcpc']['dbname']['keystone']};"
            mysql -uroot -e "GRANT ALL ON #{node['bcpc']['dbname']['keystone']}.* TO '#{get_config('mysql-keystone-user')}'@'%' IDENTIFIED BY '#{get_config('mysql-keystone-password')}';"
            mysql -uroot -e "GRANT ALL ON #{node['bcpc']['dbname']['keystone']}.* TO '#{get_config('mysql-keystone-user')}'@'localhost' IDENTIFIED BY '#{get_config('mysql-keystone-password')}';"
            mysql -uroot -e "FLUSH PRIVILEGES;"
        ]
        self.notifies :run, "bash[keystone-database-sync]", :immediately
        self.resolve_notification_references
    end
    not_if { system "MYSQL_PWD=#{get_config('mysql-root-password')} mysql -uroot -e 'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = \"#{node['bcpc']['dbname']['keystone']}\"'|grep \"#{node['bcpc']['dbname']['keystone']}\" >/dev/null" }
end

bash "keystone-database-sync" do
    action :nothing
    user "root"
    code "keystone-manage db_sync"
    notifies :restart, "service[apache2]", :immediately
end

ruby_block "keystone-region-creation" do
    block do
        %x[ export MYSQL_PWD=#{get_config('mysql-root-password')};
            mysql -uroot -e "INSERT INTO keystone.region (id, extra) VALUES(\'#{node['bcpc']['region_name']}\', '{}');"
        ]
    end
    not_if { system "MYSQL_PWD=#{get_config('mysql-root-password')} mysql -uroot -e 'SELECT id FROM keystone.region WHERE id = \"#{node['bcpc']['region_name']}\"' | grep \"#{node['bcpc']['region_name']}\" >/dev/null" }
end

# this is a synchronization resource that polls Keystone on the VIP to verify that it's not returning 503s,
# if something above has restarted Apache and Keystone isn't ready to play yet
bash "wait-for-keystone-to-become-operational" do
  code ". /root/keystonerc; until keystone user-list >/dev/null 2>&1; do sleep 1; done"
  timeout node['bcpc']['keystone']['wait_for_keystone_timeout']
end



bash "keystone-create-admin-user" do
    user "root"
    code <<-EOH
        . /root/adminrc
        . /root/keystonerc
       keystone user-create --name "$OS_USERNAME" --pass "$OS_PASSWORD"  --enabled true
    EOH
    not_if ". /root/keystonerc; . /root/adminrc; keystone user-get $OS_USERNAME"
end


bash "keystone-create-admin-tenant" do
    user "root"
    code <<-EOH
        . /root/adminrc
        . /root/keystonerc
        keystone tenant-create --name "#{node['bcpc']['admin_tenant']}" --description "Admin services"
    EOH
    not_if ". /root/keystonerc; . /root/adminrc; keystone tenant-get '#{node['bcpc']['admin_tenant']}'"
end

bash "keystone-create-admin-role" do
    user "root"
    code <<-EOH
        . /root/adminrc
        . /root/keystonerc
        keystone role-create --name "#{node['bcpc']['admin_role']}"
    EOH
    not_if ". /root/keystonerc; . /root/adminrc; keystone role-get '#{node['bcpc']['admin_role']}'"
end


bash "keystone-create-member-role" do
    user "root"
    code <<-EOH
        . /root/adminrc
        . /root/keystonerc
        keystone role-create --name "#{node['bcpc']['member_role']}"
    EOH
    not_if ". /root/keystonerc; . /root/adminrc; keystone role-get '#{node['bcpc']['member_role']}'"
end


bash "keystone-create-admin-user-role" do
    user "root"
    code <<-EOH
        . /root/adminrc
        . /root/keystonerc
        keystone user-role-add --user  "$OS_USERNAME"  --role "#{node['bcpc']['admin_role']}" --tenant "#{node['bcpc']['admin_tenant']}"
    EOH
    not_if ". /root/keystonerc; . /root/adminrc; keystone user-role-list --user  $OS_USERNAME  --tenant '#{node['bcpc']['admin_tenant']}'   | grep '#{node['bcpc']['admin_role']}'"
end

# create services and endpoints
node['bcpc']['catalog'].each do |svc, svcprops|
  ruby_block "keystone-create-#{svc}-service" do
    block do
      %x[
        export OS_TOKEN="#{get_config('keystone-admin-token')}";
        export OS_URL="#{node['bcpc']['protocol']['keystone']}://openstack.#{node['bcpc']['cluster_domain']}:#{node['bcpc']['catalog']['identity']['ports']['admin']}/#{node['bcpc']['catalog']['identity']['uris']['admin']}/";
        openstack service create --name '#{svcprops['name']}' --description '#{svcprops['description']}' #{svc}
      ]
    end
    only_if {
      services_raw = %x[
        export OS_TOKEN=\"#{get_config('keystone-admin-token')}\";
        export OS_URL=\"#{node['bcpc']['protocol']['keystone']}://openstack.#{node['bcpc']['cluster_domain']}:#{node['bcpc']['catalog']['identity']['ports']['admin']}/#{node['bcpc']['catalog']['identity']['uris']['admin']}/\";
        openstack service list -f json
      ]
      services = JSON.parse(services_raw)
      services.select { |s| s['Type'] == svc }.length.zero?
    }
  end

  ruby_block "keystone-create-#{svc}-endpoint" do
    block do
      %x[
        export OS_TOKEN="#{get_config('keystone-admin-token')}";
        export OS_URL="#{node['bcpc']['protocol']['keystone']}://openstack.#{node['bcpc']['cluster_domain']}:#{node['bcpc']['catalog']['identity']['ports']['admin']}/#{node['bcpc']['catalog']['identity']['uris']['admin']}/";
        openstack endpoint create \
            --region '#{node['bcpc']['region_name']}' \
            --publicurl '#{node['bcpc']['protocol'][svcprops['project']]}://openstack.#{node['bcpc']['cluster_domain']}:#{svcprops['ports']['public']}/#{svcprops['uris']['public']}' \
            --adminurl '#{node['bcpc']['protocol'][svcprops['project']]}://openstack.#{node['bcpc']['cluster_domain']}:#{svcprops['ports']['admin']}/#{svcprops['uris']['admin']}' \
            --internalurl '#{node['bcpc']['protocol'][svcprops['project']]}://openstack.#{node['bcpc']['cluster_domain']}:#{svcprops['ports']['internal']}/#{svcprops['uris']['internal']}' \
            #{svc}
      ]
    end
    only_if {
      endpoints_raw = %x[
        export OS_TOKEN=\"#{get_config('keystone-admin-token')}\";
        export OS_URL=\"#{node['bcpc']['protocol']['keystone']}://openstack.#{node['bcpc']['cluster_domain']}:#{node['bcpc']['catalog']['identity']['ports']['admin']}/#{node['bcpc']['catalog']['identity']['uris']['admin']}/\";
        openstack endpoint list -f json
      ]
      endpoints = JSON.parse(endpoints_raw)
      endpoints.select { |e| e['Service Type'] == svc }.length.zero?
    }
  end
end
