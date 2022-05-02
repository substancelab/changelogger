# frozen_string_literal: true

require "dotenv"
Dotenv.load

require "graphql/client"
require "graphql/client/http"

# https://docs.github.com/en/graphql/
module GitHub
  # Configure GraphQL endpoint using the basic HTTP network adapter.
  HTTP = GraphQL::Client::HTTP.new("https://api.github.com/graphql") do
    def headers(context)
      # Optionally set any HTTP headers
      {
        "Authorization" => "bearer #{ENV.fetch('GITHUB_PERSONAL_ACCESS_TOKEN')}",
        "User-Agent" => "Changelogger CLI"
      }
    end
  end

  # Fetch latest schema on init, this will make a network request
  Schema = GraphQL::Client.load_schema(HTTP)

  Client = GraphQL::Client.new(schema: Schema, execute: HTTP)
end

PullRequestsOnRepositoryQuery = GitHub::Client.parse <<-'GRAPHQL'
  query($repo_name: String!, $owner: String!) {
    repository(name: $repo_name, owner: $owner) {
      milestones(first: 10, orderBy: {direction: DESC, field: DUE_DATE}) {
        nodes {
          dueOn
          title
          issues(first:100) {
            nodes {
              closed
              title
              url
              labels(first: 100) {
                nodes {
                  name
                }
              }
            }
          }
          pullRequests(first: 100) {
            nodes {
              closed
              title
              url
              labels(first: 100) {
                nodes {
                  name
                }
              }
            }
          }
        }
      }
    }
  }
GRAPHQL

def find_milestone_with_title(pull_requests, title)
  pull_requests.data.repository.milestones.nodes.find { |ms|
    ms.title.casecmp?(title)
  }
end

def recently_completed_milestone(pull_requests)
  pull_requests.data.repository.milestones.nodes.find { |ms|
    Time.parse(ms.due_on) < Time.now
  }
end

repo = ARGV[0]
raise "Repository name must be supplied as ARGV[0]" if repo.nil?

owner, repo_name = repo.split("/")

pull_requests = GitHub::Client.query(
  PullRequestsOnRepositoryQuery,
  :variables => {
    :owner => owner,
    :repo_name => repo_name,
  }
)
response = pull_requests.to_h
raise response["errors"].inspect if response["errors"]

milestone_name = ARGV[1]
milestone = if milestone_name
  find_milestone_with_title(pull_requests, milestone_name)
else
  recently_completed_milestone(pull_requests)
end

puts milestone.title
puts "-" * milestone.title.size
puts

changes = {
  :regular => [],
  :security => [],
  :dependencies => [],
}

milestone.issues.nodes.each do |pull_request|
  next unless pull_request.closed

  labels = pull_request.labels.nodes.map(&:name)
  if labels.include?("security")
    changes[:security] << pull_request
  elsif labels.include?("dependencies")
    changes[:dependencies] << pull_request
  else
    changes[:regular] << pull_request
  end
end

milestone.pull_requests.nodes.each do |pull_request|
  next unless pull_request.closed

  labels = pull_request.labels.nodes.map(&:name)
  if labels.include?("security")
    changes[:security] << pull_request
  elsif labels.include?("dependencies")
    changes[:dependencies] << pull_request
  else
    changes[:regular] << pull_request
  end
end

[:regular, :security].each do |category|
  changes[category].sort_by(&:title).each do |pull_request|
    puts "* #{pull_request.title}: #{pull_request.url}"
    puts
  end
end

bumped_dependencies = changes[:dependencies].
  map(&:title).
  map { |title|
    title.match(/Bump (.*?) from/)[1]
  }.
  sort.
  uniq
puts "* Bumped #{bumped_dependencies.join(', ')}."
