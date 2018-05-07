# Output config file for ELB for a given region
def generate_config_ELB(awsregion,awsservice)
  elbinstances = Array.new

  Aws.config.update({
    region: "#{awsregion}",
  })

  elb = Aws::ElasticLoadBalancing::Client.new(region: awsregion)
  elb.describe_load_balancers.each do |instances|
    instances.load_balancer_descriptions.each do |instance|
      unless $skipinstances.nil?
        unless $skipinstances['ELB'].nil?
          if $skipinstances['ELB'].include? "#{load_balancer_name}"
            $log.debug("Skipping config for: #{load_balancer_name} (on skipinstances list)")
            next
          end
        end
      end

      instancename = instance.load_balancer_name

      elbinstance = Hash.new
      # ELB doesn't have a distinct ID separate from the name - so set both the same
      elbinstance['name'] = instancename
      elbinstance['id'] = instancename
      elbinstance["tags"] = Hash.new
      elb.describe_tags({ load_balancer_names: [ "#{instancename}" ] }).tag_descriptions.each do |tags|
        tags.tags.each do |tag|
          elbinstance["tags"]["#{tag.key}"]  = "#{tag.value}"
        end
      end

      # TODO: What's the right way to figure out if both a parent and child are null?
      unless $matchtags.nil?
        unless $matchtags['ELB'].nil?
          # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
          includeinstance=false

          $matchtags['ELB'].each do |matchtag|
            includeinstance=true if elbinstance["tags"].contain?( matchtag )
          end

          if (includeinstance == false)
            $log.debug("Skipping config for: #{elbinstance['name']} (matchtags doesn't include a tag for it)")
            next
          end
        end
      end

      elbinstances.push(elbinstance)
    end
  end

  dimensionname = $dimensionname["#{awsservice}"]
  buildjson(awsregion,elbinstances,"#{awsservice}","detailed",60,"#{dimensionname}")
end
