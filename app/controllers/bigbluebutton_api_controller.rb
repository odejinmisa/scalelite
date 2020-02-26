# frozen_string_literal: true

class BigBlueButtonApiController < ApplicationController
  include ApiHelper

  before_action :verify_checksum, except: :index

  def index
    # Return the scalelite build number if passed as an env variable
    build_number = Rails.configuration.x.build_number

    builder = Nokogiri::XML::Builder.new do |xml|
      xml.response do
        xml.returncode('SUCCESS')
        xml.version('2.0')
        xml.build(build_number) if build_number.present?
      end
    end

    render(xml: builder)
  end

  def get_meeting_info
    params.require(:meetingID)

    begin
      meeting = Meeting.find(params[:meetingID])
    rescue ApplicationRedisRecord::RecordNotFound
      # Respond with MeetingNotFoundError if the meeting could not be found
      logger.info("The requested meeting #{params[:meetingID]} does not exist")
      raise MeetingNotFoundError
    end

    server = meeting.server
    # Construct getMeetingInfo call with the right url + secret and checksum
    uri = encode_bbb_uri('getMeetingInfo',
                         server.url,
                         server.secret,
                         'meetingID' => params[:meetingID])

    begin
      # Send a GET request to the server
      response = get_post_req(uri)
    rescue BBBError
      # Reraise the error
      raise
    rescue StandardError => e
      logger.warn("Error #{e} accessing meeting #{params[:meetingID]} on server.")
      raise InternalError, 'Unable to access meeting on server.'
    end

    # Render response from the server
    render(xml: response)
  end

  def is_meeting_running
    params.require(:meetingID)

    begin
      meeting = Meeting.find(params[:meetingID])
    rescue ApplicationRedisRecord::RecordNotFound
      # Respond with false if the meeting could not be found
      logger.info("The requested meeting #{params[:meetingID]} does not exist")
      return render(xml: not_running_response)
    end

    server = meeting.server

    # Construct getMeetingInfo call with the right url + secret and checksum
    uri = encode_bbb_uri('isMeetingRunning',
                         server.url,
                         server.secret,
                         'meetingID' => params[:meetingID])

    begin
      # Send a GET request to the server
      response = get_post_req(uri)
    rescue BBBError
      # Reraise the error
      raise
    rescue StandardError => e
      logger.warn("Error #{e} accessing meeting #{params[:meetingID]} on server.")
      raise InternalError, 'Unable to access meeting on server.'
    end

    # Render response from the server
    render(xml: response)
  end

  def get_meetings
    # Get all available servers
    servers = Server.all

    logger.warn('No servers are currently available') if servers.empty?

    builder = Nokogiri::XML::Builder.new do |xml|
      xml.response do
        xml.returncode('SUCCESS')
        xml.meetings
      end
    end

    all_meetings = builder.doc
    meetings_node = all_meetings.at_xpath('/response/meetings')

    # Make individual getMeetings call for each server and append result to all_meetings
    servers.each do |server|
      uri = encode_bbb_uri('getMeetings', server.url, server.secret)

      begin
        # Send a GET request to the server
        response = get_post_req(uri)

        # Skip over if no meetings on this server
        server_meetings = response.xpath('/response/meetings/meeting')
        next if server_meetings.empty?

        # Add all meetings returned from the getMeetings call to the list
        meetings_node.add_child(server_meetings)
      rescue BBBError => e
        raise e
      rescue StandardError => e
        logger.warn("Error #{e} accessing server #{server.id}.")
        raise InternalError, 'Unable to access server.'
      end
    end

    # Render all meetings if there are any or a custom no meetings response if no meetings exist
    render(xml: meetings_node.children.empty? ? no_meetings_response : all_meetings)
  end

  def create
    params.require(:meetingID)

    begin
      server = Server.find_available
    rescue ApplicationRedisRecord::RecordNotFound
      raise InternalError, 'Could not find any available servers.'
    end

    # Create meeting in database
    logger.debug("Creating meeting #{params[:meetingID]} in database.")
    meeting = Meeting.find_or_create_with_server(params[:meetingID], server)

    # Update with old server if meeting already existed in database
    server = meeting.server

    logger.debug("Incrementing server #{server.id} load by 1")
    server.increment_load(1)

    duration = params[:duration].to_i

    # Set/Overite duration if MAX_MEETING_DURATION is set and it's greater than params[:duration] (if passed)
    if !Rails.configuration.x.max_meeting_duration.zero? &&
       (duration.zero? || duration > Rails.configuration.x.max_meeting_duration)
      logger.debug("Setting duration to #{Rails.configuration.x.max_meeting_duration}")
      params[:duration] = Rails.configuration.x.max_meeting_duration
    end

    logger.debug("Creating meeting #{params[:meetingID]} on BigBlueButton server #{server.id}")
    # Pass along all params except the built in rails ones
    uri = encode_bbb_uri('create', server.url, server.secret, pass_through_params)

    begin
      # Send a GET/POST request to the server
      response = get_post_req(uri, request.post? ? request.body.read : '')

      # TODO: handle create post for preupload presentations
    rescue BBBError
      # Reraise the error to return error xml to caller
      raise
    rescue StandardError => e
      logger.warn("Error #{e} creating meeting #{params[:meetingID]} on server #{server.id}.")
      raise InternalError, 'Unable to create meeting on server.'
    end

    # Render response from the server
    render(xml: response)
  end

  def end
    params.require(:meetingID)

    begin
      meeting = Meeting.find(params[:meetingID])
    rescue ApplicationRedisRecord::RecordNotFound
      # Respond with MeetingNotFoundError if the meeting could not be found
      logger.info("The requested meeting #{params[:meetingID]} does not exist")
      raise MeetingNotFoundError
    end

    server = meeting.server

    # Construct end call with the right params
    uri = encode_bbb_uri('end', server.url, server.secret,
                         meetingID: params[:meetingID], password: params[:password])

    begin
      # Send a GET request to the server
      response = get_post_req(uri)
    rescue BBBError => e
      if e.message_key == 'notFound'
        # If the meeting is not found, delete the meeting from the load balancer database
        logger.debug("Meeting #{params[:meetingID]} not found on server; deleting from database.")
        meeting.destroy!
      end
      # Reraise the error
      raise e
    rescue StandardError => e
      logger.warn("Error #{e} accessing meeting #{params[:meetingID]} on server #{server.id}.")
      raise InternalError, 'Unable to access meeting on server.'
    end

    # Render response from the server
    render(xml: response)
  end

  def join
    params.require(:meetingID)

    begin
      meeting = Meeting.find(params[:meetingID])
    rescue ApplicationRedisRecord::RecordNotFound
      # Respond with MeetingNotFoundError if the meeting could not be found
      logger.info("The requested meeting #{params[:meetingID]} does not exist")
      raise MeetingNotFoundError
    end

    server = meeting.server

    # Pass along all params except the built in rails ones
    uri = encode_bbb_uri('join', server.url, server.secret, pass_through_params)

    # Redirect the user to the join url
    logger.debug("Redirecting user to join url: #{uri}")
    redirect_to(uri.to_s)
  end

  def get_recordings
    query = Recording.includes(playback_formats: [:thumbnails], metadata: [])
    query = query.with_recording_id_prefixes(params[:recordID].split(',')) if params[:recordID].present?
    query = query.where(meeting_id: params[:meetingID].split(',')) if params[:meetingID].present?

    @recordings = query.order(starttime: :desc).all
    @url_prefix = "#{request.protocol}#{request.host}"

    render(:get_recordings)
  end

  def publish_recordings
    raise BBBError.new('missingParamRecordID', 'You must specify a recordID.') if params[:recordID].blank?
    raise BBBError.new('missingParamPublish', 'You must specify a publish value true or false.') if params[:publish].blank?

    publish = params[:publish].casecmp('true').zero?

    Recording.transaction do
      query = Recording.where(record_id: params[:recordID].split(','), state: 'published')
      raise BBBError.new('notFound', 'We could not find recordings') if query.none?

      query.where.not(published: publish).update_all(published: publish) # rubocop:disable Rails/SkipsModelValidations
    end

    @published = publish
    render(:publish_recordings)
  end

  def update_recordings
    raise BBBError.new('missingParamRecordID', 'You must specify a recordID.') if params[:recordID].blank?

    add_metadata = {}
    remove_metadata = []
    params.each do |key, value|
      next unless key.start_with?('meta_')

      key = key[5..-1].downcase

      if value.blank?
        remove_metadata << key
      else
        add_metadata[key] = value
      end
    end

    logger.debug("Adding metadata: #{add_metadata}")
    logger.debug("Removing metadata: #{remove_metadata}")

    record_ids = params[:recordID].split(',')
    Metadatum.transaction do
      Metadatum.upsert_by_record_id(record_ids, add_metadata)
      Metadatum.delete_by_record_id(record_ids, remove_metadata)
    end

    @updated = !(add_metadata.empty? && remove_metadata.empty?)
    render(:update_recordings)
  end

  private

  # Filter out unneeded params when passing through to join and create calls
  # Has to be to_unsafe_hash since to_h only accepts permitted attributes
  def pass_through_params
    params.except(:format, :controller, :action, :checksum).to_unsafe_hash
  end

  # Success response if there are no meetings on any servers
  def no_meetings_response
    Nokogiri::XML::Builder.new do |xml|
      xml.response do
        xml.returncode('SUCCESS')
        xml.messageKey('noMeetings')
        xml.message('No meetings were found on this server.')
      end
    end
  end

  # Not running response if meeting doesn't exist in database
  def not_running_response
    Nokogiri::XML::Builder.new do |xml|
      xml.response do
        xml.returncode('SUCCESS')
        xml.running('false')
      end
    end
  end
end
