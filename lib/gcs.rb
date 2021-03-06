# coding: utf-8

require "net/http"
require "cgi"
require "json"

require "gcs/version"
require "google/apis/storage_v1"

require_relative "gcs/gcs_writer"

class Gcs
  include Google::Apis::StorageV1
  def initialize(email_address = nil, private_key = nil, scope: "cloud-platform", request_options: {retries: 10})
    @api = Google::Apis::StorageV1::StorageService.new
    @api.request_options = @api.request_options.merge(request_options)
    scope_url = "https://www.googleapis.com/auth/#{scope}"
    if email_address and private_key
      auth = Signet::OAuth2::Client.new(
        token_credential_uri: "https://accounts.google.com/o/oauth2/token",
        audience: "https://accounts.google.com/o/oauth2/token",
        scope: scope_url,
        issuer: email_address,
        signing_key: private_key)
    else
      auth = Google::Auth.get_application_default([scope_url])
    end
    auth.fetch_access_token!
    @api.authorization = auth
  end

  def buckets(project_id)
    @api.list_buckets(project_id, max_results: 1000).items || []
  end

  def bucket(name)
    @api.get_bucket(name)
  rescue Google::Apis::ClientError
    if $!.status_code == 404
      return nil
    else
      raise
    end
  end

  def insert_bucket(project_id, name, storage_class: "STANDARD", acl: nil, default_object_acl: nil, location: nil)
    b = Bucket.new(
      name: name,
      storage_class: storage_class
    )
    b.location = location if location
    b.acl = acl if acl
    b.default_object_acl = default_object_acl if default_object_acl
    @api.insert_bucket(project_id, b)
  end

  def delete_bucket(name)
    @api.delete_bucket(name)
  rescue Google::Apis::ClientError
    if $!.status_code == 404
      return nil
    else
      raise
    end
  end

  def self.ensure_bucket_object(bucket, object=nil)
    if object.nil? and bucket.start_with?("gs://")
      bucket = bucket.sub(%r{\Ags://}, "")
      bucket, object = bucket.split("/", 2)
    end
    return [bucket, object]
  end

  def _ensure_bucket_object(bucket, object=nil)
    self.class.ensure_bucket_object(bucket, object)
  end

  def get_object(bucket, object=nil, download_dest: nil)
    bucket, object = _ensure_bucket_object(bucket, object)
    begin
      obj = @api.get_object(bucket, object)
      if download_dest
        @api.get_object(bucket, object, generation: obj.generation, download_dest: download_dest)
      end
      obj
    rescue Google::Apis::ClientError
      if $!.status_code == 404
        return nil
      else
        raise
      end
    end
  end

  def read_partial(bucket, object=nil, limit: 1024*1024, trim_after_last_delimiter: nil, &blk)
    bucket, object = _ensure_bucket_object(bucket, object)
    uri = URI("https://storage.googleapis.com/download/storage/v1/b/#{CGI.escape(bucket)}/o/#{CGI.escape(object).gsub("+", "%20")}?alt=media")
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      req = Net::HTTP::Get.new(uri.request_uri)
      req["Authorization"] = "Bearer #{fetch_access_token}"
      http.request(req) do |res|
        case res
        when Net::HTTPSuccess
          if blk
            res.read_body(&blk)
            return res
          else
            total = "".force_encoding(Encoding::ASCII_8BIT)
            res.read_body do |part|
              total << part
              if total.bytesize > limit
                break
              end
            end
            if trim_after_last_delimiter
              i = total.rindex(trim_after_last_delimiter.force_encoding(Encoding::ASCII_8BIT))
              if i.nil?
                # If no delimiter was found, return empty string.
                # This is because caller expect not to incomplete line. (ex: Newline Delimited JSON)
                i = -1
              end
              total[(i+1)..-1] = ""
            end
            return total
          end
        when Net::HTTPNotFound
          return nil
        else
          raise "Gcs.read_partial failed with HTTP status #{res.code}: #{res.body}"
        end
      end
    end
  end

  def list_objects(bucket, delimiter: "/", prefix: "", page_token: nil, max_results: nil)
    if bucket.start_with?("gs://")
      bucket, prefix = _ensure_bucket_object(bucket)
    end
    @api.list_objects(bucket, delimiter: delimiter, prefix: prefix, page_token: page_token, max_results: max_results)
  end

  def delete_object(bucket, object=nil, if_generation_match: nil)
    bucket, object = _ensure_bucket_object(bucket, object)
    @api.delete_object(bucket, object, if_generation_match: if_generation_match)
  end

  # @param [String] bucket
  # @param [String] object name
  # @param [String|IO] source
  # @param [String] content_type
  # @param [String] content_encoding
  #
  # @return [Google::Apis::StorageV1::Object]
  def insert_object(bucket, name, source, content_type: nil, content_encoding: nil, if_generation_match: nil)
    bucket, name = _ensure_bucket_object(bucket, name)
    obj = Google::Apis::StorageV1::Object.new(name: name)
    @api.insert_object(bucket, obj, content_encoding: content_encoding, upload_source: source, content_type: content_type,
                       if_generation_match: if_generation_match)
  end

  def rewrite(src_bucket, src_object, dest_bucket, dest_object, if_generation_match: nil)
    r = @api.rewrite_object(src_bucket, src_object, dest_bucket, dest_object, if_generation_match: if_generation_match)
    until r.done
      r = @api.rewrite_object(src_bucket, src_object, dest_bucket, dest_object, rewrite_token: r.rewrite_token, if_generation_match: if_generation_match)
    end
    r
  end

  def copy_tree(src, dest)
    src_bucket, src_path = self.class.ensure_bucket_object(src)
    dest_bucket, dest_path = self.class.ensure_bucket_object(dest)
    src_path = src_path + "/" unless src_path[-1] == "/"
    dest_path = dest_path + "/" unless dest_path[-1] == "/"
    res = list_objects(src_bucket, prefix: src_path)
    (res.items || []).each do |o|
      next if o.name[-1] == "/"
      dest_obj_name = dest_path + o.name.sub(/\A#{Regexp.escape(src_path)}/, "")
      self.rewrite(src_bucket, o.name, dest_bucket, dest_obj_name)
    end
    (res.prefixes || []).each do |p|
      copy_tree("gs://#{src_bucket}/#{p}", "gs://#{dest_bucket}/#{dest_path}#{p.sub(/\A#{Regexp.escape(src_path)}/, "")}")
    end
  end

  def copy_object(src, dest)
    src_bucket, src_path = self.class.ensure_bucket_object(src)
    dest_bucket, dest_path = self.class.ensure_bucket_object(dest)
    self.rewrite(src_bucket, src_path, dest_bucket, dest_path)
  end

  def compose_object(source_objs, dest, content_type: nil, content_encoding: nil)
    source_objs = Array(source_objs)
    if source_objs.size > 32
      raise "The number of components to be composed into single object should be equal or less than 32."
    end
    dest_bucket, dest_object = self.class.ensure_bucket_object(dest)
    source_bucket = nil
    sobjs = []
    source_objs.each do |spat|
      b, _ = self.class.ensure_bucket_object(spat)
      source_bucket ||= b
      unless source_bucket == b and source_bucket == dest_bucket
        raise "The all components objects should be placed in the same bucket to compose objects."
      end
      matched_names = []
      glob(spat) do |obj|
        matched_names << obj.name
        if (sobjs | matched_names).size > 32
          raise "The number of components to be composed into single object should be equal or less than 32."
        end
      end
      if matched_names.empty?
        raise "No object found or no matched objects found for '#{spat}'"
      end
      sobjs |= matched_names
    end
    dest_obj = Google::Apis::StorageV1::Object.new(
      bucket: dest_bucket,
      name: dest_object,
      content_type: content_type,
      content_encoding: content_encoding)
    @api.compose_object(dest_bucket, dest_object,
                        Google::Apis::StorageV1::ComposeRequest.new(destination: dest_obj,
                                                                    source_objects: sobjs.map{|so| Google::Apis::StorageV1::ComposeRequest::SourceObject.new(name: so) }))
  end

  def remove_tree(gcs_url)
    bucket, path = self.class.ensure_bucket_object(gcs_url)
    if path.size > 0 and path[-1] != "/"
      path = path + "/"
    end
    next_page_token = nil
    loop do
      begin
        res = list_objects(bucket, prefix: path, delimiter: nil, page_token: next_page_token)
      rescue Google::Apis::ClientError
        if $!.status_code == 404
          return nil
        else
          raise
        end
      end

      # batch request あたりの API 呼び出しの量は API の種類によって異なり
      # Cloud Storage JSON API のドキュメントでは 100 となってるけど1000でもいけたので1000に変更
      # ref. https://cloud.google.com/storage/docs/json_api/v1/how-tos/batch
      (res.items || []).each_slice(1000) do |objs|
        @api.batch do
          objs.each do |o|
            @api.delete_object(bucket, o.name) {|_, err| raise err if err and (not(err.respond_to?(:status_code)) or (err.status_code != 404))}
          end
        end
      end
      break unless res.next_page_token
      next_page_token = res.next_page_token
    end
  end

  def initiate_resumable_upload(bucket, object=nil, content_type: "application/octet-stream", origin_domain: nil)
    bucket, object = self.class.ensure_bucket_object(bucket, object)
    uri = URI("https://storage.googleapis.com/upload/storage/v1/b/#{CGI.escape(bucket)}/o?uploadType=resumable")
    http = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      req = Net::HTTP::Post.new(uri.request_uri)
      req["content-type"] = "application/json; charset=UTF-8"
      req["Authorization"] = "Bearer #{fetch_access_token}"
      req["X-Upload-Content-Type"] = content_type
      if origin_domain
        req["Origin"] = origin_domain
      end
      req.body = JSON.generate({ "name" => object })
      res = http.request(req)
      return res["location"]
    end
  end

  def fetch_access_token
    auth = @api.authorization
    if Time.now - auth.issued_at > auth.expires_in - 60 # set some margin to get rid of clock deviation etc.
      auth.refresh!
    end
    auth.access_token
  end

  def glob(bucket, object=nil)
    bucket, object_pattern = self.class.ensure_bucket_object(bucket, object)
    prefix, = object_pattern.split(/(?<!\\)\*/, 2)
    page_token = nil
    loop do
      ret = list_objects(bucket, prefix: prefix, delimiter: nil, page_token: page_token)
      (ret.items || []).each do |obj|
        if File.fnmatch(object_pattern, obj.name)
          yield obj
        end
      end
      page_token = ret.next_page_token
      break if page_token.nil?
    end
    nil
  end
end
