# frozen_string_literal: true
module Blacklight
  # This class encapsulates the search state as represented by the query
  # parameters namely: :f, :q, :page, :per_page and, :sort
  class SearchState
    attr_reader :blacklight_config # Must be called blacklight_config, because Blacklight::Facet calls blacklight_config.
    attr_reader :params

    # This method is never accessed in this class, but may be used by subclasses that need
    # to access the url_helpers
    attr_reader :controller

    delegate :facet_configuration_for_field, to: :blacklight_config

    # @param [ActionController::Parameters] params
    # @param [Blacklight::Config] blacklight_config
    # @param [ApplicationController] controller used for the routing helpers
    def initialize(params, blacklight_config, controller = nil)
      @params = self.class.normalize_params(params)
      @blacklight_config = blacklight_config
      @controller = controller
    end

    def self.normalize_params(untrusted_params = {})
      params = untrusted_params

      if params.respond_to?(:to_unsafe_h)
        # This is the typical (not-ActionView::TestCase) code path.
        params = params.to_unsafe_h
        # In Rails 5 to_unsafe_h returns a HashWithIndifferentAccess, in Rails 4 it returns Hash
        params = params.with_indifferent_access if params.instance_of? Hash
      elsif params.is_a? Hash
        # This is an ActionView::TestCase workaround for Rails 4.2.
        params = params.dup.with_indifferent_access
      else
        params = params.dup.to_h.with_indifferent_access
      end

      # Normalize facet parameters mangled by facebook
      if params[:f].is_a?(Hash) && params[:f].values.any? { |x| x.is_a?(Hash) }
        params[:f] = params[:f].transform_values do |value|
          value.is_a?(Hash) ? value.values : value
        end
      end

      params
    end

    def to_hash
      @params
    end
    alias to_h to_hash

    def to_unsafe_h
      Deprecation.warn(self, 'Use SearchState#to_h instead of SearchState#to_unsafe_h')
      to_hash
    end

    def method_missing(method_name, *arguments, &block)
      if @params.respond_to?(method_name)
        Deprecation.warn(self, "Calling `#{method_name}` on Blacklight::SearchState " \
          'is deprecated and will be removed in Blacklight 8. Call #to_h first if you ' \
          ' need to use hash methods (or, preferably, use your own SearchState implementation)')
        @params.public_send(method_name, *arguments, &block)
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @params.respond_to?(method_name, include_private) || super
    end

    # Tiny shim to make it easier to migrate raw params access to using this class
    delegate :[], to: :params
    deprecation_deprecate :[]

    def has_constraints?
      !(query_param.blank? && filter_params.blank?)
    end

    def query_param
      params[:q]
    end

    def filter_params
      params[:f] || {}
    end

    def reset(params = nil)
      self.class.new(params || ActionController::Parameters.new, blacklight_config, controller)
    end

    ##
    # Extension point for downstream applications
    # to provide more interesting routing to
    # documents
    def url_for_document(doc, options = {})
      if respond_to?(:blacklight_config) &&
          blacklight_config.show.route &&
          (!doc.respond_to?(:to_model) || doc.to_model.is_a?(SolrDocument))
        route = blacklight_config.show.route.merge(action: :show, id: doc).merge(options)
        route[:controller] = params[:controller] if route[:controller] == :current
        route
      else
        doc
      end
    end

    def remove_query_params
      p = reset_search_params
      p.delete(:q)
      p
    end

    # adds the value and/or field to params[:f]
    # Does NOT remove request keys and otherwise ensure that the hash
    # is suitable for a redirect. See
    # add_facet_params_and_redirect
    def add_facet_params(field, item)
      p = reset_search_params

      add_facet_param(p, field, item)

      if item && item.respond_to?(:fq) && item.fq
        Array(item.fq).each do |f, v|
          add_facet_param(p, f, v)
        end
      end

      p
    end

    # Used in catalog/facet action, facets.rb view, for a click
    # on a facet value. Add on the facet params to existing
    # search constraints. Remove any paginator-specific request
    # params, or other request params that should be removed
    # for a 'fresh' display.
    # Change the action to 'index' to send them back to
    # catalog/index with their new facet choice.
    def add_facet_params_and_redirect(field, item)
      new_params = add_facet_params(field, item)

      # Delete any request params from facet-specific action, needed
      # to redir to index action properly.
      request_keys = blacklight_config.facet_paginator_class.request_keys
      new_params.extract!(*request_keys.values)

      new_params
    end

    # copies the current params (or whatever is passed in as the 3rd arg)
    # removes the field value from params[:f]
    # removes the field if there are no more values in params[:f][field]
    # removes additional params (page, id, etc..)
    # @param [String] field
    # @param [String] item
    def remove_facet_params(field, item)
      if item.respond_to? :field
        field = item.field
      end

      facet_config = facet_configuration_for_field(field)

      url_field = facet_config.key

      value = facet_value_for_facet_item(item)

      p = reset_search_params
      # need to dup the facet values too,
      # if the values aren't dup'd, then the values
      # from the session will get remove in the show view...
      p[:f] = (p[:f] || {}).dup
      p[:f][url_field] = (p[:f][url_field] || []).dup

      collection = p[:f][url_field]
      # collection should be an array, because we link to ?f[key][]=value,
      # however, Facebook (and maybe some other PHP tools) tranform that parameters
      # into ?f[key][0]=value, which Rails interprets as a Hash.
      if collection.is_a? Hash
        collection = collection.values
      end
      p[:f][url_field] = collection - [value]
      p[:f].delete(url_field) if p[:f][url_field].empty?
      p.delete(:f) if p[:f].empty?
      p
    end

    def has_facet?(config, value: nil)
      facet = params&.dig(:f, config.key)

      if value
        (facet || []).include? value
      else
        facet.present?
      end
    end

    # Merge the source params with the params_to_merge hash
    # @param [Hash] params_to_merge to merge into above
    # @return [ActionController::Parameters] the current search parameters after being sanitized by Blacklight::Parameters.sanitize
    # @yield [params] The merged parameters hash before being sanitized
    def params_for_search(params_to_merge = {})
      # params hash we'll return
      my_params = params.dup.merge(self.class.new(params_to_merge, blacklight_config, controller))

      if block_given?
        yield my_params
      end

      if my_params[:page] && (my_params[:per_page] != params[:per_page] || my_params[:sort] != params[:sort])
        my_params[:page] = 1
      end

      Parameters.sanitize(my_params)
    end

    private

    ##
    # Reset any search parameters that store search context
    # and need to be reset when e.g. constraints change
    # @return [ActionController::Parameters]
    def reset_search_params
      Parameters.sanitize(params).except(:page, :counter)
    end

    # TODO: this code is duplicated in Blacklight::FacetsHelperBehavior
    def facet_value_for_facet_item item
      if item.respond_to? :value
        item.value
      else
        item
      end
    end

    def add_facet_param(p, field, item)
      if item.respond_to? :field
        field = item.field
      end

      facet_config = facet_configuration_for_field(field)

      url_field = facet_config.key

      value = facet_value_for_facet_item(item)

      p[:f] = (p[:f] || {}).dup # the command above is not deep in rails3, !@#$!@#$
      p[:f][url_field] = (p[:f][url_field] || []).dup

      if facet_config.single && p[:f][url_field].present?
        p[:f][url_field] = []
      end

      p[:f][url_field].push(value)
    end
  end
end
