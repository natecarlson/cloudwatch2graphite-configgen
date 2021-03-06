require 'pp'

# Output config file for ElastiCache for a given region
# TODO: Check state of cluster before trying to generate configs.
def generate_config_ElastiCache(awsregion,awsservice)
  elasticacheinstances = Array.new
  elasticachenodeinstancesredis = Array.new
  elasticachenodeinstancesmemcache = Array.new

  Aws.config.update({
    region: "#{awsregion}",
  })

  elasticache = Aws::ElastiCache::Client.new(region: awsregion)
  elasticache.describe_cache_clusters({ show_cache_node_info: true }).each do |instances|
    instances.cache_clusters.each do |instance|
      instanceid = instance.cache_cluster_id

      unless $skipinstances.nil?
        unless $skipinstances['ElastiCache'].nil?
          if $skipinstances['ElastiCache'].include? "#{instanceid}"
            $log.debug("Skipping config for: #{instanceid} (on skipinstances list)")
            next
          end
        end
      end

      elasticacheinstance = Hash.new
      elasticacheinstance['id'] = instanceid
      elasticacheinstance['arn'] = "arn:aws:elasticache:#{awsregion}:#{$awsaccountnumber}:cluster:#{instanceid}"
      elasticacheinstance["tags"] = Hash.new
      elasticache.list_tags_for_resource({ resource_name: "#{elasticacheinstance['arn']}" }).tag_list.each do |tags|
        elasticacheinstance["tags"]["#{tags.key}"]  = "#{tags.value}"
      end
      elasticacheinstance['name'] = elasticacheinstance["tags"]["Name"]

      # TODO: What's the right way to figure out if both a parent and child are null?
      unless $matchtags.nil?
        unless $matchtags['ElastiCache'].nil?
          # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
          includeinstance=false

          $matchtags['ElastiCache'].each do |matchtag|
            includeinstance=true if elasticacheinstance["tags"].contain?( matchtag )
          end

          if (includeinstance == false)
            $log.debug("Skipping config for: #{elasticacheinstance['name']} (matchtags doesn't include a tag for it)")
            next
          end
        end
      end

      # Memcache is always a single instance with many cache_nodes but
      # if there are Shards for Redis, there will be multiple instances with singular cache_node
      case instance.engine.downcase
      when 'memcached'
        # Iterate over the nodes..
        instance.cache_nodes.each do |cache_node|
          elasticachenodeinstance = Hash.new
          # Cache Node ID
          elasticachenodeinstance['id'] = cache_node.cache_node_id
          # Re-use the ID (which will be something like '0001') as the name too..
          elasticachenodeinstance['name'] = cache_node.cache_node_id
          # Specify parent ELB, for use in the json building exercise
          elasticachenodeinstance['parent'] = elasticacheinstance['name']
          # Ugh. Also need to include parent id, as have to do two dimensions..
          elasticachenodeinstance['parentid'] = elasticacheinstance['id']

          elasticachenodeinstancesmemcache.push(elasticachenodeinstance)
        end
      when 'redis'
        elasticachenodeinstance = Hash.new

        # There are two cases to handle, cluster-enable=yes and cluster-enable=no
        # For cluster-enabled, ElastiCache does the shard and node in the cache_cluster_id
        if instance.cache_cluster_id.match(/(.*)-\d+-\d+$/).nil?
          # We hit a cluster-enabled=no so shard needs to staticly be 0001 
          ids_match = instance.cache_cluster_id.match(/.*-(\d+)$/)
          shard = '0001'
          display_id = ids_match[1]
          # Strip out the name
          display_name = instance.cache_cluster_id.match(/(.*)-\d+$/)[1]
        else
          # Strip out the shard and the node, both digits
          ids_match = instance.cache_cluster_id.match(/.*-(\d+)-(\d+)$/)
          shard = ids_match[1]
          display_id = ids_match[2]
          # Strip out the name
          display_name = instance.cache_cluster_id.match(/(.*)-\d+-\d+$/)[1]
        end
        
        # Actual Cache Node ID for API
        elasticachenodeinstance['id'] = instance.cache_nodes[0].cache_node_id
        # Display Name of this Cache Node ID for buildjson
        elasticachenodeinstance['name'] = display_id
        # Specify Parent, like name and shard for use in the json building exercise
        elasticachenodeinstance['parent'] = "#{display_name}.#{shard}"
        # Ugh. Also need to include parent id, as have to do two dimensions..
        elasticachenodeinstance['parentid'] = instance.cache_cluster_id

        elasticachenodeinstancesredis.push(elasticachenodeinstance)
      end
      elasticacheinstances.push(elasticacheinstance)
    end
  end

  dimensionname = $dimensionname["#{awsservice}"]
  # Don't have to generate the top-level, no stats stored there..
  #buildjson(awsregion,applicationelbinstances,"#{awsservice}","detailed",60,"#{dimensionname}")

  # Generate JSON for Memcache nodes
  buildjson(awsregion,elasticachenodeinstancesmemcache,"ElastiCache-Node-Memcache","detailed",60,"CacheNodeId")
  # Generate JSON for Redis nodes
  buildjson(awsregion,elasticachenodeinstancesredis,"ElastiCache-Node-Redis","detailed",60,"CacheNodeId")
end
