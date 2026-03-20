require 'spec_helper'
require_relative '../../../../files/api/activity'

describe PeEventForwarding::Activity do
  subject(:activity) { described_class.new('dummy', token: 'token') }

  # activity.rb uses log.debug (not log&.debug), so we need a verifying double against ::Logger
  let(:logger) { instance_double(::Logger, debug: nil) }

  before(:each) do
    activity.pe_client = instance_double('PeEventForwarding::PeHttp')
    activity.log = logger
  end

  context '#get_events' do
    # The PE Activity API calls individual event records "commits" — each commit
    # is a transaction (e.g. an RBAC change, a classifier update). Internally
    # get_events iterates response_body['commits'] and re-exposes them as 'events'.
    let(:commits) { [{ 'id' => 1 }, { 'id' => 2 }] }
    let(:pagination) { { 'total' => 10 } }

    it 'returns events and total count from a single page' do
      body = { 'commits' => commits, 'pagination' => pagination }.to_json
      response = instance_double('response', body: body, code: '200')
      allow(activity.pe_client).to receive(:pe_get_request).and_return(response)

      result = activity.get_events(service: :rbac, api_page_size: 100, timeout: 5)
      expect(result['events'].count).to eq(2)
      expect(result['api_total_count']).to eq(10)
    end

    it 'stops paginating when the page is shorter than api_page_size' do
      body = { 'commits' => commits, 'pagination' => pagination }.to_json
      response = instance_double('response', body: body, code: '200')
      expect(activity.pe_client).to receive(:pe_get_request).once.and_return(response)

      # api_page_size 5, only 2 commits returned -> 2 != 5 -> break after one page
      activity.get_events(service: :rbac, api_page_size: 5, timeout: 5)
    end

    it 'paginates when a full page is returned' do
      full_page = [{ 'id' => 0 }, { 'id' => 1 }]
      body1 = { 'commits' => full_page, 'pagination' => pagination }.to_json
      body2 = { 'commits' => [], 'pagination' => pagination }.to_json
      response1 = instance_double('response', body: body1, code: '200')
      response2 = instance_double('response', body: body2, code: '200')
      expect(activity.pe_client).to receive(:pe_get_request).twice.and_return(response1, response2)

      # api_page_size 2, first page full -> continues; second page empty -> 0 != 2 -> break
      result = activity.get_events(service: :rbac, api_page_size: 2, timeout: 5)
      expect(result['events'].count).to eq(2)
    end

    it 'handles nil commits without raising' do
      body = { 'commits' => nil, 'pagination' => { 'total' => 0 } }.to_json
      response = instance_double('response', body: body, code: '200')
      allow(activity.pe_client).to receive(:pe_get_request).and_return(response)

      result = activity.get_events(service: :rbac, api_page_size: 10, timeout: 5)
      expect(result['events']).to be_empty
    end

    it 'raises when API returns non-200' do
      body = { 'commits' => [], 'pagination' => { 'total' => 0 } }.to_json
      response = instance_double('response', body: body, code: '500')
      allow(activity.pe_client).to receive(:pe_get_request).and_return(response)

      expect { activity.get_events(service: :rbac, api_page_size: 10, timeout: 5) }
        .to raise_error(RuntimeError, 'Events API request failed')
    end
  end

  context '#current_event_count' do
    it 'returns the total count from pagination' do
      body = { 'pagination' => { 'total' => 42 } }.to_json
      response = instance_double('response', body: body, code: '200')
      allow(activity.pe_client).to receive(:pe_get_request).and_return(response)

      expect(activity.current_event_count(:rbac, 5)).to eq(42)
    end

    it 'returns 0 when total is nil' do
      body = { 'pagination' => {} }.to_json
      response = instance_double('response', body: body, code: '200')
      allow(activity.pe_client).to receive(:pe_get_request).and_return(response)

      expect(activity.current_event_count(:rbac, 5)).to eq(0)
    end

    it 'raises when API returns non-200' do
      response = instance_double('response', body: {}.to_json, code: '500')
      allow(activity.pe_client).to receive(:pe_get_request).and_return(response)

      expect { activity.current_event_count(:rbac, 5) }
        .to raise_error(RuntimeError, 'Events API request failed')
    end
  end

  # rubocop:disable RSpec/SubjectStub
  context '#new_data' do
    it 'returns nil when event count has not changed' do
      allow(activity).to receive(:current_event_count).and_return(5)
      expect(activity.new_data(:rbac, 5, 100, 30)).to be_nil
    end

    it 'returns nil when event count decreased' do
      allow(activity).to receive(:current_event_count).and_return(3)
      expect(activity.new_data(:rbac, 5, 100, 30)).to be_nil
    end

    it 'calls get_events with the correct offset when new events exist' do
      allow(activity).to receive(:current_event_count).and_return(7)
      expect(activity).to receive(:get_events)
        .with(service: :rbac, offset: 5, api_page_size: 100, timeout: 30)
      activity.new_data(:rbac, 5, 100, 30)
    end
  end
  # rubocop:enable RSpec/SubjectStub
end
