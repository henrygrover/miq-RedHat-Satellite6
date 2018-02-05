# Creates a Satellite host record for the given VM provisining request.
# The created host record is in build mode.
#
# EXPECTED
#   EVM ROOT
#     miq_provision - VM Provisining request to create the Satellite host record for.
#       required options:
#         satellite_organization_id - Satellite Organization ID to register the VM with
#         satellite_location_id     - Satellite Location ID to register the VM with
#         satellite_hostgroup_id    - Satellite Hostgroup ID to register the VM with
#         satellite_domain_id       - Satellite Domain ID to register the VM with
#
# @see https://www.theforeman.org/api/1.14/index.html - POST /api/hosts 
#
@DEBUG = false

require 'apipie-bindings'
require 'rest-client'
require 'json'
require 'url_base64'

# Log an error and exit.
#
# @param msg Message to error with
def error(msg)
  $evm.log(:error, msg)
  $evm.root['ae_result'] = 'error'
  $evm.root['ae_reason'] = msg.to_s
  exit MIQ_STOP
end

def rest_request(action, url, payload=nil)
  params = {
    :method=>action, :url=>url, :verify_ssl=>false,
    :headers=>{ :content_type=>:json, :accept=>:json,
                :authorization=>"Basic #{url_base64.strict_encode64("#{username}:#{password}")}"}
    }
  params[:payload] = payload if payload
  response = RestClient::Request.new(params).execute
  return JSON.parse(response)
end

SATELLITE_CONFIG_URI = 'Integration/Satellite/Configuration/default'
INFOBLOX_CONFIG_URI = 'Integration/Infoblox/IPAM/default'

# Gets an ApiPie binding to the Satellite API.
#
# @return ApipieBindings to the Satellite API
def get_satellite_api()
  satellite_config = $evm.instantiate(SATELLITE_CONFIG_URI)
  error("Satellite Configuration not found") if satellite_config.nil?
  
  satellite_server   = satellite_config['satellite_server']
  satellite_username = satellite_config['satellite_username']
  satellite_password = satellite_config.decrypt('satellite_password')
  
  $evm.log(:info, "satellite_server   = #{satellite_server}") if @DEBUG
  $evm.log(:info, "satellite_username = #{satellite_username}") if @DEBUG
  
  error("Satellite Server configuration not found")   if satellite_server.nil?
  error("Satellite User configuration not found")     if satellite_username.nil?
  error("Satellite Password configuration not found") if satellite_password.nil?
  
  satellite_api = ApipieBindings::API.new({:uri => satellite_server, :username => satellite_username, :password => satellite_password, :api_version => 2})
  $evm.log(:info, "satellite_api = #{satellite_api}") if @DEBUG
  return satellite_api
end

begin
  satellite_api = get_satellite_api()
  infoblox_config = $evm.instantiate(INFOBLOX_CONFIG_URI)
  
  # Get provisioning object
  prov = $evm.root['miq_provision']
  error('Provisioning request not found') if prov.nil?
  $evm.log(:info, "Provision:<#{prov.id}> Request:<#{prov.miq_provision_request.id}> Type:<#{prov.type}>")
  $evm.log(:info, "prov.attributes => {")                               if @DEBUG
  prov.attributes.sort.each { |k,v| $evm.log(:info, "\t#{k} => #{v}") } if @DEBUG
  $evm.log(:info, "}")                                                  if @DEBUG
  
  # get the VM
  vm = prov.vm
  error('VM on provisining request not found') if vm.nil?
  $evm.log(:info, "vm = #{vm}") if @DEBUG
  
  name                      = vm.name
  mac                       = vm.mac_addresses[0]

  ip = nil #Let Satellite assign an IP unless Infoblox has been configured
  unless infoblox_config.nil?
    infoblox_server   = infoblox_config['server']
    infoblox_username = infoblox_config['username']
    infoblox_password = infoblox_config.decrypt('password')
    infoblox_api_version = infoblox_config['api_version']

    url_base = "#{infoblox_server}/wapi/#{infoblox_api_version}/"

    #TODO How do we identify the right subnet?
    payload = {
      "name"=>name,
      "ipv4addrs"=>[{"ipv4addr"=>"func:nextavailableip:172.31.0.0/24"}],
      "configure_for_dns"=>false
    }

    creation_result = rest_request(:post, "#{url_base}record:host", payload.to_json)
    new_record = rest_request(:get, "#{url_base}#{creation_result}")
    ip = new_record["ipv4addrs"].first["ipv4addr"] || nil

    error("Failed to get IP from Infoblox") if ip.nil?
  end


  satellite_organization_id = prov.get_option(:satellite_organization_id) || prov.get_option(:ws_values)[:satellite_organization_id]
  satellite_location_id     = prov.get_option(:satellite_location_id)     || prov.get_option(:ws_values)[:satellite_location_id]
  satellite_hostgroup_id    = prov.get_option(:satellite_hostgroup_id)    || prov.get_option(:ws_values)[:satellite_hostgroup_id]
  satellite_domain_id       = prov.get_option(:satellite_domain_id)       || prov.get_option(:ws_values)[:satellite_domain_id]
  
  error("Required miq_provision option <satellite_organization_id> not found") if satellite_organization_id.nil?
  error("Required miq_provision option <satellite_location_id> not found")     if satellite_location_id.nil?
  error("Required miq_provision option <satellite_hostgroup_id> not found")    if satellite_hostgroup_id.nil?
  error("Required miq_provision option <satellite_domain_id> not found")       if satellite_domain_id.nil?

  new_host_request = {
    :name                  => name,
    :organization_id       => satellite_organization_id,
    :location_id           => satellite_location_id,
    :hostgroup_id          => satellite_hostgroup_id,
    :domain_id             => satellite_domain_id,
    :managed               => true,
    :build                 => true,
    :provision_method      => 'build',
    :mac                   => mac,
    :ip                    => ip,
    :interfaces_attributes => [
      { :identifier => 'eth0',
        :primary    => true,
        :provision  => true,
        :managed    => true,
        :mac        => mac,
        :ip         => ip,
        :domain_id  => satellite_domain_id
      }
    ]
  }
  $evm.log(:info, "new_host_request => #{new_host_request}")
  
  # create Satellite Host record
  begin
    satellite_host_record = satellite_api.resource(:hosts).call(:create, { :host => new_host_request })
    $evm.log(:info, "satellite_host_record => #{satellite_host_record}")
  rescue RestClient::UnprocessableEntity => e
    error("Received an UnprocessableEntity error from Satellite. Check /var/log/foreman/production.log on Satellite for more info.")
  rescue Exception => e
    error("Error creating Satellite host record: #{e.message}")
  end
  
  # store the satellite host record id for future use in provisioning and future retirment
  prov.set_option(:satellite_host_id, satellite_host_record['id'])
  vm.custom_set('satellite_host_id', satellite_host_record['id'])
  $evm.log("info", ":satellite_host_id => '#{satellite_host_record['id']}'")
end
