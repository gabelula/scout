require 'httparty'
require './subscriptions/helpers'

module Subscriptions

  class Manager

    def self.search(subscription, options = {})
      poll subscription, :search, options
    end
    
    def self.initialize!(subscription)

      # default strategy:
      # 1) does the initial poll
      # 2) stores every item ID as seen 

      # make initialization idempotent, remove any existing seen items first
      subscription.seen_items.delete_all

      unless results = Subscriptions::Manager.poll(subscription, :initialize)
        Admin.report Report.failure("Initialization", 
          "Error while initializing a subscription, subscription is remaining uninitialized.", 
          :subscription => subscription.attributes
          )
        return nil
      end

      results.each do |item|
        mark_as_seen! subscription, item
      end
      
      subscription.initialized = true
      subscription.last_checked_at = Time.now
      subscription.save!
    end
    
    def self.check!(subscription)
      
      # catch any items which suddenly appear, dated in the past, 
      # that weren't caught during initialization or prior polls
      backfills = []

      # default strategy:
      # 1) does a poll
      # 2) stores any items as yet unseen by this subscription in seen_ids
      # 3) stores any items as yet unseen by this subscription in the delivery queue
      unless results = Subscriptions::Manager.poll(subscription, :check)
        Admin.report Report.warning("Check", "Error while checking a subscription, will check again next time.", :subscription_id => subscription.id)
        return nil
      end

      results.each do |item|

        unless SeenItem.where(:subscription_id => subscription.id, :item_id => item.item_id).first
          unless item.item_id
            Admin.report Report.warning("Check", "[#{subscription.id}][#{subscription.subscription_type}][#{subscription.interest_in}] item with an empty ID")
            next
          end

          mark_as_seen! subscription, item

          # accumulate backfilled items to report per-subscription.
          # buffer of 8 days, to allow for information to make its way through whatever 
          # pipelines it has to go through (could eventually configure this per-adapter)
          
          # Was 5 days, bumped it to 30 because of federal_bills. The LOC, CRS, and GPO all 
          # move in waves, apparently, of unpredictable frequency.
          if item.date < 30.days.ago
            backfills << item.attributes
            next
          end

          Deliveries::Manager.schedule_delivery! item, subscription
        end
      end

      if backfills.any?
        Admin.report Report.warning("Check", "[#{subscription.subscription_type}][#{subscription.interest_in}] #{backfills.size} backfills delivered, attached", :backfills => backfills)
      end
      
      subscription.last_checked_at = Time.now
      subscription.save!
    end
    
    def self.mark_as_seen!(subscription, item)
      item.save!
    end
    
    # function is one of [:search, :initialize, :check]
    # options hash can contain epheremal modifiers for search (right now just a 'page' parameter)
    def self.poll(subscription, function = :search, options = {})
      adapter = subscription.adapter
      url = adapter.url_for subscription, function, options
      
      puts "\n[#{subscription.subscription_type}][#{function}][#{subscription.interest_in}][#{subscription.id}] #{url}\n\n" if config[:debug][:output_urls]
      
      begin
        response = HTTParty.get url
      rescue Timeout::Error, Errno::ETIMEDOUT => ex
        # will do function-specific reports in places that call poll
        # Admin.report Report.warning("Poll", "[#{subscription.subscription_type}][#{function}][#{subscription.interest_in}] poll timeout, returned an empty list")
        return nil
      end
      
      items = adapter.items_for response, function, options

      if items
        
        items.map do |item| 

          interest_type = search_adapters[subscription.subscription_type] || interest_adapters[subscription.subscription_type]

          item.attributes = {
            # store the subscription, duplicate the type
            :subscription => subscription,
            :subscription_type => subscription.subscription_type,
            
            # store the interest, and duplicate some core fields
            :interest_id => subscription.interest_id,
            :interest_in => subscription.interest_in,
            :interest_type => interest_type,

            :user_id => subscription.user_id,

            # insert a reference to the URL this result was found in  
            :search_url => url
          }

          item
        end
      else
        nil
      end
    end

    # given a type of adapter, and an item ID, fetch the item and return a seen item
    def self.find(adapter_type, item_id, data = {})
      adapter = Subscription.adapter_for adapter_type
      url = adapter.url_for_detail item_id, data
      
      puts "\n[#{adapter}][find][#{item_id}] #{url}\n\n" if config[:debug][:output_urls]
      
      begin
        response = HTTParty.get url
      rescue Timeout::Error, Errno::ETIMEDOUT => ex
        Admin.report Report.warning("Find", "[#{adapter_type}][find][#{item_id}] find timeout, returned nil")
        return nil
      end
      
      item = adapter.item_detail_for response
      item.find_url = url
      item
    end
    
  end
  
end