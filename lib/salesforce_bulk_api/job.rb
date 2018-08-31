module SalesforceBulkApi

  class Job
    include Concerns::Utils

    attr_reader :job_id

    class SalesforceException < StandardError; end

    def initialize(args)
      @job_id         = args[:job_id]
      @operation      = args[:operation]
      @sobject        = args[:sobject]
      @external_field = args[:external_field]
      @records        = args[:records]
      @connection     = args[:connection]
      @batch_ids      = []
      @XML_HEADER     = '<?xml version="1.0" encoding="utf-8" ?>'
      @content_type   = args.fetch(:content_type, :xml)
    end

    def create_job(batch_size, send_nulls, no_null_list)
      @batch_size = batch_size
      @send_nulls = send_nulls
      @no_null_list = no_null_list

      xml = "#{@XML_HEADER}<jobInfo xmlns=\"http://www.force.com/2009/06/asyncapi/dataload\">"
      xml += "<operation>#{@operation}</operation>"
      xml += "<object>#{@sobject}</object>"
      # This only happens on upsert
      if !@external_field.nil?
        xml += "<externalIdFieldName>#{@external_field}</externalIdFieldName>"
      end
      xml += "<contentType>#{@content_type.upcase}</contentType>"
      xml += "</jobInfo>"

      path = "job"
      headers = Hash['Content-Type' => 'application/xml; charset=utf-8']

      response = @connection.post_xml(nil, path, xml, headers)
      response_parsed = XmlSimple.xml_in(response)

      # response may contain an exception, so raise it
      raise SalesforceException.new("#{response_parsed['exceptionMessage'][0]} (#{response_parsed['exceptionCode'][0]})") if response_parsed['exceptionCode']

      @job_id = response_parsed['id'][0]
    end

    def close_job
      xml = "#{@XML_HEADER}<jobInfo xmlns=\"http://www.force.com/2009/06/asyncapi/dataload\">"
      xml += "<state>Closed</state>"
      xml += "</jobInfo>"

      path = "job/#{@job_id}"
      headers = Hash['Content-Type' => 'application/xml; charset=utf-8']

      response = @connection.post_xml(nil, path, xml, headers)
      XmlSimple.xml_in(response)
    end

    def add_query
      path = "job/#{@job_id}/batch/"
      headers = Hash['Content-Type' => "#{content_type_header}; charset=utf-8"]

      response = @connection.post_xml(nil, path, @records, headers)
      response_parsed = XmlSimple.xml_in(response)
      @batch_ids << response_parsed['id'][0]
    end

    def add_batches
      raise 'Records must be an array of hashes.' unless @records.is_a? Array
      keys = @records.reduce({}) {|h, pairs| pairs.each {|k, v| (h[k] ||= []) << v}; h}.keys

      @records_dup = @records.clone

      super_records = []
      (@records_dup.size / @batch_size).to_i.times do
        super_records << @records_dup.pop(@batch_size)
      end
      super_records << @records_dup unless @records_dup.empty?

      super_records.each do |batch|
        @batch_ids << add_batch(keys, batch)
      end
    end

    def add_batch(keys, batch)
      xml = "#{@XML_HEADER}<sObjects xmlns=\"http://www.force.com/2009/06/asyncapi/dataload\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
      batch.each do |r|
        xml += create_sobject(keys, r)
      end
      xml += '</sObjects>'
      path = "job/#{@job_id}/batch/"
      headers = Hash['Content-Type' => 'application/xml; charset=utf-8']
      response = @connection.post_xml(nil, path, xml, headers)
      response_parsed = XmlSimple.xml_in(response)
      response_parsed['id'][0] if response_parsed['id']
    end

    def build_sobject(data)
      xml = '<sObject>'
      data.keys.each do |k|
        if k.is_a?(Hash)
          xml += build_sobject(k)
        elsif data[k] != :type
          xml += "<#{k}>#{data[k]}</#{k}>"
        end
      end
      xml += '</sObject>'
    end

    def create_sobject(keys, r)
      sobject_xml = '<sObject>'
      keys.each do |k|
        if r[k].is_a?(Hash)
          sobject_xml += "<#{k}>"
          sobject_xml += build_sobject(r[k])
          sobject_xml += "</#{k}>"
        elsif !r[k].to_s.empty?
          sobject_xml += "<#{k}>"
          if r[k].respond_to?(:encode)
            sobject_xml += r[k].encode(:xml => :text)
          elsif r[k].respond_to?(:iso8601) # timestamps
            sobject_xml += r[k].iso8601.to_s
          else
            sobject_xml += r[k].to_s
          end
          sobject_xml += "</#{k}>"
        elsif @send_nulls && !@no_null_list.include?(k)
          sobject_xml += "<#{k} xsi:nil=\"true\"/>"
        end
      end
      sobject_xml += '</sObject>'
      sobject_xml
    end

    def check_job_status
      path = "job/#{@job_id}"
      headers = Hash.new
      response = @connection.get_request(nil, path, headers)

      begin
        response_parsed = XmlSimple.xml_in(response) if response
        response_parsed
      rescue StandardError => e
        puts "Error parsing XML response for #{@job_id}"
        puts e
        puts e.backtrace
      end
    end

    def check_batch_status_all
      path = "job/#{@job_id}/batch"
      response = @connection.get_request(nil, path, {})
      response_parsed = XmlSimple.xml_in(response)
      response_parsed
    rescue StandardError => e
      puts "Error parsing XML response for #{@job_id}"
      puts e
      puts e.backtrace
    end

    def check_batch_status(batch_id)
      path = "job/#{@job_id}/batch/#{batch_id}"
      response = @connection.get_request(nil, path, {})

      begin
        response_parsed = XmlSimple.xml_in(response) if response
        response_parsed
      rescue StandardError => e
        puts "Error parsing XML response for #{@job_id}, batch #{batch_id}"
        puts e
        puts e.backtrace
      end
    end

    def get_job_result(return_result, timeout)
      # timeout is in seconds
      begin
        state = []
        Timeout::timeout(timeout, SalesforceBulkApi::JobTimeout) do
          while true
            if self.check_job_status['state'][0] == 'Closed'
              batch_statuses = {}

              batches_ready = @batch_ids.all? do |batch_id|
                batch_state = batch_statuses[batch_id] = self.check_batch_status(batch_id)
                batch_state['state'][0] != "Queued" && batch_state['state'][0] != "InProgress"
              end

              if batches_ready
                @batch_ids.each do |batch_id|
                  state.insert(0, batch_statuses[batch_id])
                  @batch_ids.delete(batch_id)
                end
              end
              break if @batch_ids.empty?
            else
              break
            end
          end
        end
      rescue SalesforceBulkApi::JobTimeout => e
        puts 'Timeout waiting for Salesforce to process job batches #{@batch_ids} of job #{@job_id}.'
        puts e
        raise
      end

      state.each_with_index do |batch_state, i|
        if batch_state['state'][0] == 'Completed' && return_result == true
          state[i].merge!({'response' => self.get_batch_result(batch_state['id'][0])})
        end
      end
      state
    end

    def get_batch_result(batch_id)
      path = "job/#{@job_id}/batch/#{batch_id}/result"
      headers = Hash['Content-Type' => 'application/xml; charset=utf-8']

      response = @connection.get_request(nil, path, headers)
      response_parsed = XmlSimple.xml_in(response)
      results = response_parsed['result'] unless @operation == 'query' || @operation == 'queryAll'

      if(@operation == 'query' || @operation == 'queryAll') # The query op requires us to do another request to get the results
        result_id = response_parsed["result"][0]
        path = "job/#{@job_id}/batch/#{batch_id}/result/#{result_id}"
        headers = Hash.new
        headers = Hash['Content-Type' => 'application/xml; charset=utf-8']
        response = @connection.get_request(nil, path, headers)
        response_parsed = XmlSimple.xml_in(response)
        results = response_parsed['records']
      end
      results
    end

    # Get query result by CSV
    def get_query_result(batch_id, filepath)
      headers = Hash['Content-Type' => 'text/csv; charset=utf-8']
      result_ids_for(batch_id).each_with_index do |result_id, i|
        path = "job/#{@job_id}/batch/#{batch_id}/result/#{result_id}"
        response = @connection.get_request(nil, path, headers)
        tmppath  = filepath.sub(".csv", "_#{i+1}.csv")
        save_to_file(response, tmppath)
      end
    end

    # @return [Array]
    def result_ids_for(batch_id)
      path = "job/#{@job_id}/batch/#{batch_id}/result"
      headers = Hash['Content-Type' => 'application/xml; charset=utf-8']
      response = @connection.get_request(nil, path, headers)
      response_parsed = XmlSimple.xml_in(response)
      response_parsed["result"]
    end

    private

    def content_type_header
      case @content_type
      when :csv
        return 'text/csv'
      when :xml
        return 'application/xml'
      when :json
        return 'application/json'
      end
    end
  end

  class JobTimeout < StandardError
  end
end
