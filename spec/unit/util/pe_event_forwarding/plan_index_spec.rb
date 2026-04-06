require 'spec_helper'
require_relative '../../../../files/util/plan_index'

describe PeEventForwarding::PlanIndex do
  subject(:plan_index) { described_class.new(statedir) }

  let(:statedir) { 'blah' }
  let(:filepath) { "#{statedir}/pe_event_forwarding_plan_index.yaml" }
  let(:initial_yaml) { { 'last_finished' => nil, 'ids_at_last_finished' => [] }.to_yaml }

  before(:each) do
    allow(File).to receive(:exist?).with(filepath).and_return(true)
    allow(File).to receive(:read).and_return(initial_yaml)
  end

  context '.initialize' do
    context 'file does not already exist' do
      before(:each) do
        allow(File).to receive(:exist?).with(filepath).and_return(false)
      end

      it 'creates a new file with correct content' do
        expect(File).to receive(:write).with(filepath, initial_yaml)
        plan_index
      end
    end

    context 'file does exist' do
      it 'does not create a new file' do
        expect(File).not_to receive(:write)
        plan_index
      end

      it 'returns nil for last_finished when file contains nil' do
        expect(plan_index.last_finished).to be_nil
      end
    end
  end

  context '.save' do
    it 'writes correct yaml with provided values' do
      expect(File).to receive(:write).with(filepath, { 'last_finished' => 123, 'ids_at_last_finished' => ['a'] }.to_yaml)
      plan_index.save(last_finished: 123, ids: ['a'])
    end
  end
end
