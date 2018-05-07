# Output config file for RDS for a given region
def generate_config_RDS(awsregion,awsservice)
  rdsinstances = Array.new

  Aws.config.update({
    region: "#{awsregion}",
  })

  rds = Aws::RDS::Client.new(region: awsregion)
  rds.describe_db_instances.each do |instances|
    instances.db_instances.each do |instance|
      unless $skipinstances.nil?
        unless $skipinstances['RDS'].nil?
          if $skipinstances['RDS'].include? "#{instance.db_instance_identifier}"
            $log.debug("Skipping config for: #{instance.db_instance_identifier} (on skipinstances list)")
            next
          end
        end
      end

      instancename = instance.db_instance_identifier

      # AWS's SDK is silly, and doesn't let you look up tags based on a RDS DB name. Have to
      # pass in an 'ARN' instead - and the SDK doesn't provide the ARN to us. Have to generate it.
      # Really, really lame.
      instancearn = "arn:aws:rds:#{awsregion}:#$awsaccountnumber:db:#{instancename}"

      rdsinstance = Hash.new
      # RDS doesn't have a distinct ID separate from the name - so set both the same
      rdsinstance['name'] = instancename
      rdsinstance['id'] = instancename
      rdsinstance['arn']  = instancearn
      rdsinstance["tags"] = Hash.new
      rds.list_tags_for_resource({ resource_name: instancearn }).each do |tags|
        tags.tag_list.each do |tag|
          rdsinstance["tags"]["#{tag.key}"]  = "#{tag.value}"
        end
      end

      # TODO: What's the right way to figure out if both a parent and child are null?
      unless $matchtags.nil?
        unless $matchtags['RDS'].nil?
          # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
          includeinstance=false

          $matchtags['RDS'].each do |matchtag|
            includeinstance=true if rdsinstance["tags"].contain?( matchtag )
          end

          if (includeinstance == false)
            $log.debug("Skipping config for: #{rdsinstance['name']} (matchtags doesn't include a tag for it)")
            next
          end
        end
      end

      rdsinstances.push(rdsinstance)
    end
  end

  dimensionname = $dimensionname["#{awsservice}"]
  buildjson(awsregion,rdsinstances,"#{awsservice}","detailed",60,"#{dimensionname}")
end
