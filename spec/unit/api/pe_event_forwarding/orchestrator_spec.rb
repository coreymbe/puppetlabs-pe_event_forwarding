require 'spec_helper'
require_relative '../../../../files/api/orchestrator'

describe PeEventForwarding::Orchestrator do
  subject(:orchestrator) { described_class.new('dummy', token: 'token') }

  before(:each) do
    orchestrator.pe_client = instance_double('PeEventForwarding::PeHttp')
  end

  context '#parse_timestamp' do
    it 'returns nil for nil input' do
      expect(orchestrator.parse_timestamp(nil)).to be_nil
    end

    it 'parses ISO8601 timestamp to float' do
      ts = '2020-01-02T03:04:05Z'
      expect(orchestrator.parse_timestamp(ts)).to be_within(0.001).of(Time.parse(ts).to_f)
    end

    it 'returns numeric for numeric strings' do
      expect(orchestrator.parse_timestamp('123.456')).to eq(123.456)
    end
  end

  context '#plan_job_finished_timestamp' do
    it 'returns the finished_timestamp field' do
      expect(orchestrator.plan_job_finished_timestamp({ 'finished_timestamp' => 'a' })).to eq('a')
    end

    it 'returns nil when finished_timestamp is absent' do
      expect(orchestrator.plan_job_finished_timestamp({ 'name' => 'j1' })).to be_nil
    end
  end

  context '#get_plan_jobs_since' do
    it 'fetches pages and returns finished jobs and max finished timestamp' do
      items = [
        { 'name' => 'j1', 'finished_timestamp' => '2020-01-01T00:00:00Z' },
        { 'name' => 'j2', 'finished_timestamp' => '2020-01-02T00:00:00Z' },
      ]
      response1 = instance_double('response', body: { 'items' => items }.to_json, code: '200')
      response2 = instance_double('response', body: { 'items' => [] }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response1, response2)

      res = orchestrator.get_plan_jobs_since(min_finish_timestamp: nil, limit: 2, timeout: 5)
      expect(res['events'].count).to eq(2)
      expect(res['last_finished']).to eq('2020-01-02T00:00:00Z')
    end

    it 'filters out running jobs that have no finished timestamp' do
      items = [
        { 'name' => 'j1', 'finished_timestamp' => '2020-01-01T00:00:00Z' },
        { 'name' => 'j2' },  # running – no timestamp field
      ]
      response1 = instance_double('response', body: { 'items' => items }.to_json, code: '200')
      response2 = instance_double('response', body: { 'items' => [] }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response1, response2)

      res = orchestrator.get_plan_jobs_since(min_finish_timestamp: nil, timeout: 5)
      expect(res['events'].count).to eq(1)
      expect(res['events'].first['name']).to eq('j1')
    end

    it 'returns empty events and nil last_finished when no jobs are finished' do
      items = [{ 'name' => 'j1' }, { 'name' => 'j2' }]
      response1 = instance_double('response', body: { 'items' => items }.to_json, code: '200')
      response2 = instance_double('response', body: { 'items' => [] }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response1, response2)

      res = orchestrator.get_plan_jobs_since(min_finish_timestamp: nil, timeout: 5)
      expect(res['events']).to be_empty
      expect(res['last_finished']).to be_nil
    end
  end

  # rubocop:disable RSpec/SubjectStub
  context '#new_plan_data_by_finish' do
    it 'dedupes inclusive results using processed_ids and returns remaining events' do
      res_hash = {
        'last_finished' => '2020-01-02T00:00:00Z',
        'events' => [
          { 'name' => 'j2', 'finished_timestamp' => '2020-01-02T00:00:00Z' },
          { 'name' => 'j3', 'finished_timestamp' => '2020-01-03T00:00:00Z' },
        ],
      }
      allow(orchestrator).to receive(:get_plan_jobs_since).and_return(res_hash)

      result = orchestrator.new_plan_data_by_finish('2020-01-02T00:00:00Z', 5, processed_ids: ['j2'])
      expect(result).not_to be_nil
      expect(result['events'].map { |j| j['name'] }).to eq(['j3'])
      expect(result['last_finished']).to eq('2020-01-03T00:00:00Z')
    end

    it 'returns nil when there are no finished events' do
      allow(orchestrator).to receive(:get_plan_jobs_since)
        .and_return({ 'last_finished' => nil, 'events' => [] })
      expect(orchestrator.new_plan_data_by_finish('2020-01-01T00:00:00Z', 5)).to be_nil
    end

    it 'returns nil when all events are removed by processed_ids dedupe' do
      res_hash = {
        'last_finished' => '2020-01-01T00:00:00Z',
        'events' => [{ 'name' => 'j1', 'finished_timestamp' => '2020-01-01T00:00:00Z' }],
      }
      allow(orchestrator).to receive(:get_plan_jobs_since).and_return(res_hash)
      expect(orchestrator.new_plan_data_by_finish('2020-01-01T00:00:00Z', 5, processed_ids: ['j1'])).to be_nil
    end

    it 'sorts events ascending by finished timestamp' do
      res_hash = {
        'last_finished' => '2020-01-03T00:00:00Z',
        'events' => [
          { 'name' => 'j3', 'finished_timestamp' => '2020-01-03T00:00:00Z' },
          { 'name' => 'j1', 'finished_timestamp' => '2020-01-01T00:00:00Z' },
          { 'name' => 'j2', 'finished_timestamp' => '2020-01-02T00:00:00Z' },
        ],
      }
      allow(orchestrator).to receive(:get_plan_jobs_since).and_return(res_hash)
      result = orchestrator.new_plan_data_by_finish(nil, 5)
      expect(result['events'].map { |j| j['name'] }).to eq(['j1', 'j2', 'j3'])
    end
  end
  # rubocop:enable RSpec/SubjectStub

  context '#get_jobs' do
    it 'returns events and correct api_total_count' do
      items = [{ 'name' => '2' }, { 'name' => '3' }]
      response = instance_double('response', body: { 'items' => items }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response)

      result = orchestrator.get_jobs(index_count: 1, new_jobs: 2, timeout: 5)
      expect(result['events'].count).to eq(2)
      expect(result['api_total_count']).to eq(3)
    end

    it 'paginates across multiple pages until new_jobs is satisfied' do
      page1 = [{ 'name' => '2' }, { 'name' => '3' }]
      page2 = [{ 'name' => '4' }]
      response1 = instance_double('response', body: { 'items' => page1 }.to_json, code: '200')
      response2 = instance_double('response', body: { 'items' => page2 }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response1, response2)

      result = orchestrator.get_jobs(index_count: 1, new_jobs: 3, limit: 2, timeout: 5)
      expect(result['events'].count).to eq(3)
    end

    it 'raises when API returns non-200' do
      response = instance_double('response', body: { 'items' => [] }.to_json, code: '500')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response)
      expect { orchestrator.get_jobs(index_count: 0, new_jobs: 0, timeout: 5) }
        .to raise_error(RuntimeError, 'Orchestrator API request failed')
    end
  end

  context '#current_job_count' do
    it 'returns 0 when items is empty' do
      response = instance_double('response', body: { 'items' => [] }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response)
      expect(orchestrator.current_job_count(5)).to eq(0)
    end

    it 'returns the integer name of the most recent job' do
      response = instance_double('response', body: { 'items' => [{ 'name' => '42' }] }.to_json, code: '200')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response)
      expect(orchestrator.current_job_count(5)).to eq(42)
    end

    it 'raises when API returns non-200' do
      response = instance_double('response', body: {}.to_json, code: '500')
      allow(orchestrator.pe_client).to receive(:pe_get_request).and_return(response)
      expect { orchestrator.current_job_count(5) }
        .to raise_error(RuntimeError, 'Orchestrator API request failed')
    end
  end

  # rubocop:disable RSpec/SubjectStub
  context '#new_data' do
    it 'returns nil when job count has not changed' do
      allow(orchestrator).to receive(:current_job_count).and_return(5)
      expect(orchestrator.new_data(5, 30)).to be_nil
    end

    it 'returns nil when job count decreased' do
      allow(orchestrator).to receive(:current_job_count).and_return(3)
      expect(orchestrator.new_data(5, 30)).to be_nil
    end

    it 'calls get_jobs with correct args when new jobs exist' do
      allow(orchestrator).to receive(:current_job_count).and_return(7)
      expect(orchestrator).to receive(:get_jobs).with(index_count: 5, new_jobs: 2, timeout: 30)
      orchestrator.new_data(5, 30)
    end
  end
  # rubocop:enable RSpec/SubjectStub
end
