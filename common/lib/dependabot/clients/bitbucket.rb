# frozen_string_literal: true

require "dependabot/shared_helpers"
require "excon"

module Dependabot
  module Clients
    class Bitbucket
      class NotFound < StandardError; end

      class Unauthorized < StandardError; end

      class Forbidden < StandardError; end

      #######################
      # Constructor methods #
      #######################

      def self.for_source(source:, credentials:)
        credential =
          credentials.
          select { |cred| cred["type"] == "git_source" }.
          find { |cred| cred["host"] == source.hostname }

        new(credentials: credential, source: source)
      end

      ##########
      # Client #
      ##########

      # FIXME: I don't know if changing the constructor here is safe
      def initialize(credentials:, source: nil)
        @source = source
        @credentials = credentials
        @auth_header = auth_header_for(credentials&.fetch("token", nil))
      end

      def fetch_commit(repo, branch)
        path = "#{repo}/refs/branches/#{branch}"
        response = get(base_url + path)

        JSON.parse(response.body).fetch("target").fetch("hash")
      end

      def fetch_default_branch(repo)
        response = get(base_url + repo)

        JSON.parse(response.body).fetch("mainbranch").fetch("name")
      end

      def fetch_repo_contents(repo, commit = nil, path = nil)
        raise "Commit is required if path provided!" if commit.nil? && path

        api_path = "#{repo}/src"
        api_path += "/#{commit}" if commit
        api_path += "/#{path.gsub(%r{/+$}, '')}" if path
        api_path += "?pagelen=100"
        response = get(base_url + api_path)

        JSON.parse(response.body).fetch("values")
      end

      def fetch_file_contents(repo, commit, path)
        path = "#{repo}/src/#{commit}/#{path.gsub(%r{/+$}, '')}"
        response = get(base_url + path)

        response.body
      end

      def commits(repo, branch_name = nil)
        commits_path = "#{repo}/commits/" + branch_name.to_s
        commits_path += "?pagelen=100"

        response = get(base_url + commits_path)

        JSON.parse(response.body).fetch("values")
      end

      def branch(repo, branch_name)
        branch_path = "#{repo}/refs/branches/#{branch_name}"
        response = get(base_url + branch_path)

        JSON.parse(response.body)
      end

      def pull_requests(repo, source_branch, target_branch)
        pr_path = "#{repo}/pullrequests"
        pr_path += "?status=OPEN&status=MERGED&status=DECLINED&status=SUPERSEDED"
        next_page = base_url + pr_path
        pull_requests = []
        loop do
          response = get(next_page)
          result = JSON.parse(response.body)
          pull_requests.concat result.fetch("values")
          break unless result.key?("next")

          next_page = result.fetch("next")
        end

        pull_requests unless source_branch && target_branch

        pull_requests.
          select do |pr|
            pr_source_branch = pr.fetch("source").fetch("branch").fetch("name")
            pr_target_branch = pr.fetch("destination").fetch("branch").fetch("name")
            pr_source_branch == source_branch && pr_target_branch == target_branch
          end
      end

      # rubocop:disable Metrics/ParameterLists
      def create_commit(repo, branch_name, base_commit, commit_message, files,
                        author_details)
        parameters = {
          message: commit_message, # TODO: Format markup in commit message
          author: "#{author_details.fetch(:name)} <#{author_details.fetch(:email)}>",
          parents: base_commit,
          branch: branch_name
        }

        files.each do |file|
          absolute_path = "/" + file.name unless file.name.start_with?("/")
          parameters[absolute_path] = file.content
        end

        body = encode_form_parameters(parameters)

        commit_path = "#{repo}/src"
        post(base_url + commit_path, body, "application/x-www-form-urlencoded")
      end
      # rubocop:enable Metrics/ParameterLists

      # rubocop:disable Metrics/ParameterLists
      def create_pull_request(repo, pr_name, source_branch, target_branch,
                              pr_description, _labels, _work_item = nil)
        content = {
          title: pr_name,
          source: {
            branch: {
              name: source_branch
            }
          },
          destination: {
            branch: {
              name: target_branch
            }
          },
          description: pr_description,
          close_source_branch: true
        }

        pr_path = "#{repo}/pullrequests"
        post(base_url + pr_path, content.to_json)
      end
      # rubocop:enable Metrics/ParameterLists

      def tags(repo)
        path = "#{repo}/refs/tags?pagelen=100"
        response = get(base_url + path)

        JSON.parse(response.body).fetch("values")
      end

      def compare(repo, previous_tag, new_tag)
        path = "#{repo}/commits/?include=#{new_tag}&exclude=#{previous_tag}"
        response = get(base_url + path)

        JSON.parse(response.body).fetch("values")
      end

      def get(url)
        response = Excon.get(
          url,
          user: credentials&.fetch("username", nil),
          password: credentials&.fetch("password", nil),
          idempotent: true,
          **Dependabot::SharedHelpers.excon_defaults(
            headers: auth_header
          )
        )
        raise Unauthorized if response.status == 401
        raise Forbidden if response.status == 403
        raise NotFound if response.status == 404

        if response.status >= 400
          raise "Unhandled Bitbucket error!\n"\
                "Status: #{response.status}\n"\
                "Body: #{response.body}"
        end

        response
      end

      def post(url, body, content_type = "application/json")
        response = Excon.post(
          url,
          body: body,
          user: credentials&.fetch("username", nil),
          password: credentials&.fetch("password", nil),
          idempotent: false,
          **SharedHelpers.excon_defaults(
            headers: auth_header.merge(
              {
                "Content-Type" => content_type
              }
            )
          )
        )
        raise Unauthorized if response.status == 401
        raise Forbidden if response.status == 403
        raise NotFound if response.status == 404

        response
      end

      private

      def auth_header_for(token)
        return {} unless token

        { "Authorization" => "Bearer #{token}" }
      end

      def encode_form_parameters(parameters)
        parameters.map do |key, value|
          URI.encode_www_form_component(key.to_s) + "=" + URI.encode_www_form_component(value.to_s)
        end.join("&")
      end

      attr_reader :auth_header
      attr_reader :credentials

      def base_url
        # TODO: Make this configurable when we support enterprise Bitbucket
        "https://api.bitbucket.org/2.0/repositories/"
      end
    end
  end
end
