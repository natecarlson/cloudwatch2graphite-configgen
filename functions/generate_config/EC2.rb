# Output config file for EC2 for a given region
def generate_config_EC2(awsregion,awsservice)

  # Define two lists of nodes to generate config for - basic (standard) monitoring and detailed monitoring..
  ec2instances = Hash.new
  ec2instances["detailed"] = Array.new
  ec2instances["basic"] = Array.new

  # ...and ditto for standard vs PIOPS EBS volumes
  ebsvolumes = Hash.new
  ebsvolumes["basic"] = Array.new
  ebsvolumes["detailed"] = Array.new

  Aws.config.update({
    region: "#{awsregion}",
  })

  ec2 = Aws::EC2::Client.new(region: awsregion)

  # Only filters specified here should be to get rid of cruft we don't want to see at all (non-running-machines/etc) - instances
  # to include get parsed below using tags specified in the config file.
  ec2.describe_instances({ filters: [ { name: "instance-state-name", values: ["running"] } ] } ).each do |reservations|
    reservations.reservations.each do |reservation|
      reservation.instances.each do |instance|
        @instanceid = instance.instance_id

        # Populate the ec2instance hash, which will contain all the info about the ec2 instance itself.
        ec2instance = Hash.new
        ec2instance['id'] = "#@instanceid"
        ec2instance['detailedmonitoring'] = instance.monitoring.state
        ec2instance["tags"] = Hash.new
        instance.tags.each do |tag|
          ec2instance["tags"]["#{tag.key}"]  = "#{tag.value}"
        end
        ec2instance["name"] = "#{ec2instance['tags']['Name']}"

        # Determine if this instance will be included in our list to generate configs for..

        # Check if this instance matches our 'skipinstances' list; if so, move on.
        unless $skipinstances.nil?
          unless $skipinstances['EC2'].nil?
            if $skipinstances["EC2"].include? "#{ec2instance['name']}"
              $log.debug("Skipping config for: #{ec2instance['name']} (on skipinstances list)")
              next
            end
          end
        end

        # If matchtags is defined, validated that this instance matches the tags we've defined - include it if so,
        # otherwise skip it.
        # TODO: What's the right way to figure out if both a parent and child are null?
        unless $matchtags.nil?
          unless $matchtags['EC2'].nil?
            # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
            includeinstance=false

            $matchtags['EC2'].each do |matchtag|
              includeinstance=true if ec2instance["tags"].contain?( matchtag )
            end

            if (includeinstance == false)
              $log.debug("Skipping config for: #{ec2instance['name']} (matchtags doesn't include a tag for it)")
              next
            end
          end
        end

        if ["enabled","pending"].include? ec2instance["detailedmonitoring"]
          ec2instances["detailed"].push(ec2instance)
        elsif ["disabled","disabling"].include? ec2instance["detailedmonitoring"]
          ec2instances["basic"].push(ec2instance)
        else
          $log.error("Instance #{ec2instance['tags']['Name']} (id #{ec2instance["id"]}) has an invalid field for detailed monitoring: #{ec2instance["detailedmonitoring"]}")
          abort
        end

        # Populate our EBS volumes into the 'EBS' hash.. include our instance
        # TODO: do one lookup for all volumes somehow.. this is slow!
        instance.block_device_mappings.each do |block_dev|
          next if block_dev.ebs.status != "attached"
          ebsvolume = Hash.new
          ebsvolume['id'] = block_dev.ebs.volume_id
          ebsvolume['ec2_id'] = "#@instanceid"

          # maybe these should be ec2_name and ec2_blockdev.. but this is probably what we'll refer to it as?
          ebsvolume['name'] = ec2instance['tags']['Name']
          ebsvolume['blockdev'] = block_dev.device_name

          ec2.describe_volumes({ volume_ids: ["#{block_dev.ebs.volume_id}"] }).each do |volumes|
            volumes.volumes.each do |volume| # There should only be one..
              ebsvolume['type'] = volume.volume_type
              ebsvolume['iops'] = volume.iops
              ebsvolume['size'] = volume.size
              ebsvolume["tags"] = Hash.new
              volume.tags.each do |tag|
                ebsvolume["tags"]["#{tag.key}"]  = "#{tag.value}"
              end
            end
          end

          # Logic for which EBS pool to push this into should go here..
          if ["io1"].include? ebsvolume["type"]
            ebsvolumes["detailed"].push(ebsvolume)
          elsif ["standard","gp2"].include? ebsvolume["type"]
            ebsvolumes["basic"].push(ebsvolume)
          else
            $log.error("Volume #{ebsvolume['tags']['Name']} (id #{ebsvolume["id"]}) has an invalid field for type: #{ebsvolume["type"]}")
            abort
          end
        end
      end
    end
  end

  dimensionname = $dimensionname["#{awsservice}"]

  # Build JSON for 1 minute and 5 minute intervals
  buildjson(awsregion,ec2instances["basic"],"#{awsservice}","basic",300,"#{dimensionname}")
  buildjson(awsregion,ec2instances["detailed"],"#{awsservice}","detailed",60,"#{dimensionname}")

  if $awsservices.include? "EBS"
    dimensionnameebs = $dimensionname["EBS"]
    # Build JSON for Standard and PIOPS EBS disk (5m and 1m intervals)
    buildjson(awsregion,ebsvolumes["basic"],"EBS","basic",300,"#{dimensionnameebs}")
    buildjson(awsregion,ebsvolumes["detailed"],"EBS","detailed",60,"#{dimensionnameebs}")
  end
end

