module Spree
  class Gateway::StripeGateway < PaymentMethod::CreditCard
    preference :secret_key, :string
    preference :publishable_key, :string

    CARD_TYPE_MAPPING = {
      'American Express' => 'american_express',
      'Diners Club' => 'diners_club',
      'Visa' => 'visa'
    }

    if SolidusSupport.solidus_gem_version < Gem::Version.new('2.3.x')
      def method_type
        'stripe'
      end
    else
      def partial_name
        'stripe'
      end
    end

    def gateway_class
      ActiveMerchant::Billing::StripeGateway
    end

    # Allow an environment variable to set the secret key
    def preferred_secret_key
      ENV['STRIPE_SECRET_KEY'] || self[:preferences][:secret_key]
    end

    # Allow an environment variable to set the publishable key
    def preferred_publishable_key
      ENV['STRIPE_PUBLIC_KEY'] || self[:preferences][:publishable_key]
    end

    # Base the server on the current environment
    def preferred_server
      Rails.env.production? ? 'production' : 'test'
    end

    # Base the test mode flag on the current environment
    def preferred_test_mode
      !Rails.env.production?
    end

    def payment_profiles_supported?
      true
    end

    def purchase(money, creditcard, gateway_options)
      gateway.purchase(*options_for_purchase_or_auth(money, creditcard, gateway_options))
    end

    def authorize(money, creditcard, gateway_options)
      gateway.authorize(*options_for_purchase_or_auth(money, creditcard, gateway_options))
    end

    def capture(money, response_code, gateway_options)
      gateway.capture(money, response_code, gateway_options)
    end

    def credit(money, creditcard, response_code, gateway_options)
      gateway.refund(money, response_code, {})
    end

    def void(response_code, creditcard, gateway_options)
      gateway.void(response_code, {})
    end

    def cancel(response_code)
      gateway.void(response_code, {})
    end

    def create_profile(payment)
      return unless payment.source.gateway_customer_profile_id.nil?
      options = {
        description: name_on_card(payment),
        email: payment.try(:email),
        login: preferred_secret_key
      }.merge! address_for(payment)

      source = update_source!(payment.source)
      if source.number.blank? && source.gateway_payment_profile_id.present?
        creditcard = source.gateway_payment_profile_id
      else
        creditcard = source
      end

      response = gateway.store(creditcard, options)
      if response.success?
        payment.source.update_attributes!({
          cc_type: payment.source.cc_type, # side-effect of update_source!
          gateway_customer_profile_id: response.params['id'],
          gateway_payment_profile_id: response.params['default_source'] || response.params['default_card']
        })

      else
        payment.send(:gateway_error, response)
      end
    end

    private

    def name_on_card(payment)
      if payment.manual?
        payment.source.name
      else
        payment.order.bill_address.full_name
      end
    end

    def purchase_order_number(payment)
      if payment.manual?
        payment.reference_number
      else
        payment.order.number
      end
    end

    # In this gateway, what we call 'secret_key' is the 'login'
    def options
      options = super
      options.merge(:login => preferred_secret_key)
    end

    def options_for_purchase_or_auth(money, creditcard, gateway_options)
      options = payment_options(creditcard, gateway_options)

      # Take the neccessary customer and card components from the passed credit card, and return
      # what the Stripe API is expecting.
      customer_id = creditcard.gateway_customer_profile_id
      options[:customer] = customer_id if customer_id

      payment_id = creditcard.gateway_payment_profile_id
      creditcard = payment_id if payment_id

      [money, creditcard, options]
    end


    def payment_options(creditcard, gateway_options)
      # If there's an order attached to this payment. Otherwise, it's a manual payment.
      if gateway_options.present?
        standard_payment_options(creditcard, gateway_options)
      else
        manual_payment_options(creditcard)
      end
    end

    def standard_payment_options(creditcard, gateway_options)
      order_id = get_order_id(gateway_options)

      {
        description: description(gateway_options),
        currency: gateway_options[:currency],
        idempotency_key: Digest::MD5.hexdigest([order_id, creditcard].join),
        metadata: {
          'Purchase Order Number': order_id,
          'IP Address': gateway_options[:ip]
        }
      }
    end

    def manual_payment_options(creditcard)
      payment = creditcard.payments.first

      {
        description: "#{creditcard.name} (Manual Payment)",
        currency: 'USD',
        idempotency_key: Digest::MD5.hexdigest([creditcard].join),
        metadata: {
          'Purchase Order Number': payment.reference_number,
          'Admin User': payment.user.try(:email)
        }
      }
    end

    def description(gateway_options)
      return '' unless gateway_options
      "#{gateway_options[:billing_address][:name]} (Order ##{get_order_id(gateway_options)})"
    end

    def get_order_id(gateway_options)
      gateway_options[:order_id].split('-')[0]
    end

    def address_for(payment)
      {}.tap do |options|
        if payment.manual?
          options.merge!(address: {
            address1: payment.address_line1,
            zip: payment.postal_code
          })
        else address = payment.order.bill_address
          options.merge!(address: {
            address1: address.address1,
            address2: address.address2,
            city: address.city,
            zip: address.zipcode
          })

          if country = address.country
            options[:address].merge!(country: country.name)
          end

          if state = address.state
            options[:address].merge!(state: state.name)
          end
        end
      end
    end

    def update_source!(source)
      source.cc_type = CARD_TYPE_MAPPING[source.cc_type] if CARD_TYPE_MAPPING.include?(source.cc_type)
      source
    end
  end
end
