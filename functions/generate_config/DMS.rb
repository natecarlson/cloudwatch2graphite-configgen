# Output config file for DMS for a given region
def generate_config_DMS(awsregion,awsservice)
  dmsinstances = Array.new

  Aws.config.update({
    region: "#{awsregion}",
  })

  dms = Aws::DatabaseMigrationService::Client.new(region: awsregion)
  dms.describe_replication_instances.replication_instances.each do |instances|
    #instances.each do |instance|
      unless $skipinstances.nil?
        unless $skipinstances['DMS'].nil?
          if $skipinstances['DMS'].include? "#{instances.replication_instance_identifier}"
            $log.debug("Skipping config for: #{instances.replication_instance_identifier} (on skipinstances list)")
            next
          end
        end
      end

      instancename = instances.replication_instance_identifier

      dmsinstance = Hash.new
      # DMS doesn't have a distinct ID separate from the name - so set both the same
      dmsinstance['name'] = instancename
      dmsinstance['id'] = instancename
      dmsinstances.push(dmsinstance)
    #end
  end

  dimensionname = $dimensionname["#{awsservice}"]
  buildjson(awsregion,dmsinstances,"#{awsservice}","detailed",60,"#{dimensionname}")
end
