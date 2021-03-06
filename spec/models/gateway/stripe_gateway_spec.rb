require 'spec_helper'

describe Spree::Gateway::StripeGateway do
  let(:secret_key) { 'key' }
  let(:email) { 'customer@example.com' }
  let(:source) { Spree::CreditCard.new }

  let(:payment) {
    double('Spree::Payment',
      manual?: false,
      source: source,
      order: double('Spree::Order',
        email: email,
        bill_address: bill_address
      )
    )
  }

  let(:gateway) do
    double('gateway').tap do |p|
      allow(p).to receive(:purchase)
      allow(p).to receive(:authorize)
      allow(p).to receive(:capture)
    end
  end

  before do
    subject.preferences = { secret_key: secret_key }
    allow(subject).to receive(:options_for_purchase_or_auth).and_return(['money','cc','opts'])
    allow(subject).to receive(:gateway).and_return gateway
  end

  describe '#create_profile' do
    let(:bill_address) {
      double('Spree::Address',
        full_name: 'Roger Sanderson',
        address1: '123 Happy Road',
        address2: 'Apt 303',
        city: 'Suzarac',
        zipcode: '95671',
        state: double('Spree::State', name: 'Oregon'),
        country: double('Spree::Country', name: 'United States')
      )
    }

    before do
      allow(payment.source).to receive(:update_attributes!)
    end

    context 'with an order that has a bill address' do
      it 'stores the bill address with the gateway' do
        expect(subject.gateway).to receive(:store).with(payment.source, {
          description: 'Roger Sanderson',
          email: nil,
          login: secret_key,

          address: {
            address1: '123 Happy Road',
            address2: 'Apt 303',
            city: 'Suzarac',
            zip: '95671',
            country: 'United States',
            state: 'Oregon'
          }
        }).and_return double.as_null_object

        subject.create_profile payment
      end
    end

    context 'with a card represents payment_profile' do
      let(:source) { Spree::CreditCard.new(gateway_payment_profile_id: 'tok_profileid') }

      it 'stores the profile_id as a card' do
        expect(subject.gateway).to receive(:store).with(source.gateway_payment_profile_id, anything).and_return double.as_null_object

        subject.create_profile payment
      end
    end
  end

  context 'purchasing' do
    after do
      subject.purchase(19.99, 'credit card', {})
    end

    it 'send the payment to the gateway' do
      expect(gateway).to receive(:purchase).with('money','cc','opts')
    end
  end

  context 'authorizing' do
    after do
      subject.authorize(19.99, 'credit card', {})
    end

    it 'send the authorization to the gateway' do
      expect(gateway).to receive(:authorize).with('money','cc','opts')
    end
  end

  context 'capturing' do

    after do
      subject.capture(1234, 'response_code', {})
    end

    it 'convert the amount to cents' do
      expect(gateway).to receive(:capture).with(1234,anything,anything)
    end

    it 'use the response code as the authorization' do
      expect(gateway).to receive(:capture).with(anything,'response_code',anything)
    end
  end

  context 'capture with payment class' do
    let(:gateway) do
      gateway = described_class.new(:active => true)
      gateway.set_preference :secret_key, secret_key
      allow(gateway).to receive(:options_for_purchase_or_auth).and_return(['money','cc','opts'])
      allow(gateway).to receive(:gateway).and_return gateway
      allow(gateway).to receive_messages :source_required => true
      gateway
    end

    let!(:store) { FactoryBot.create(:store) }
    let(:order) { Spree::Order.create! }

    let(:card) do
      FactoryBot.build_stubbed(
        :credit_card,
        gateway_customer_profile_id: 'cus_abcde',
        imported: false
      )
    end

    let(:payment) do
      payment = Spree::Payment.new
      payment.source = card
      payment.order = order
      payment.payment_method = gateway
      payment.amount = 98.55
      payment.state = 'pending'
      payment.response_code = '12345'
      payment
    end

    let!(:success_response) do
      double('success_response', :success? => true,
                               :authorization => '123',
                               :avs_result => { 'code' => 'avs-code' },
                               :cvv_result => { 'code' => 'cvv-code', 'message' => "CVV Result"})
    end

    after do
      payment.capture!
    end

    it 'gets correct amount' do
      expect(gateway).to receive(:capture).with(9855,'12345',anything).and_return(success_response)
    end
  end
end
