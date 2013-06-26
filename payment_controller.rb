class PaymentController < ApplicationController
  before_filter :initialize_cart
  before_filter :authenticate_user!, :find_order, :initialize_gateway
  skip_before_filter :verify_authenticity_token, only: :molpay_callback

  def pay_with_paypal
    setup_response = @paypal_gateway.setup_purchase(to_cent(@order.sub_total.to_f.ceil),
      :locale => PAYPAL_LOCALE,
      :ip => request.remote_ip,
      :return_url => paypal_callback_payment_url(@order.id),
      :cancel_return_url => paypal_cancel_payment_url(@order.id),
      :subtotal => @order.sub_total,
      :shipping => @order.total_shipping_cost,
      :allow_note =>  true
    )
    redirect_to @paypal_gateway.redirect_url_for(setup_response.token)
  end

  def paypal_callback
    purchase_response = @paypal_gateway.purchase(to_cent(@order.sub_total.to_f.ceil), {:token => params[:token], :payer_id => params[:PayerID], :ip => request.remote_ip})
    if purchase_response.success?
      @order.update_attributes(payment_id: purchase_response.params['transaction_id'],
        status: "Confirmed",
        charged_amount: purchase_response.params['gross_amount'])
      @cart.update_status_to_sold
      user = @order.user
      if user.orders.count.eql?(1)
        user.send_reward_to_inviter unless user.inviter_code.blank?
      end
      session[:cart_id] = nil
    else
      @order.update_attributes(status: purchase_response.params['payment_status'])
      @cart.update_status_to_available
      session[:cart_id] = nil
      current_user.update_attribute('credit', current_user.credit + @cart.cart_items.map(&:store_credit).sum)
    end
    @order.order_information
    redirect_to order_url(@order.id)
  end

  def paypal_cancel
    redirect_to sales_path
  end

  def pay_with_molpay
    require 'molpay/molpay'

    molpay_gateway = Molpay.new(
      amount: @order.sub_total,
      orderid: @order.id,
      bill_name: @order.user.full_name,
      bill_email: @order.user.email,
      bill_mobile: @order.user.mobile_phone,
      bill_desc: 'Order in Hishop',
      curl: 'myr',
      country: 'MY',
      returnurl: molpay_callback_payment_url(@order.id),
      vcode:
        if Rails.env == "production"
        "#{@order.sub_total}#{MOLPAY_MERCHANT_ID}#{@order.id}#{MOLPAY_VERIFY_KEY}"
      else
        "#{@order.sub_total}#{MOLPAY_MERCHANT_ID}#{@order.id}"
      end
    )
    redirect_to(molpay_gateway.purchase(@order.payment_gateway))

  end

  def molpay_callback
    if params[:status] == '00'
      status = "Confirmed"
      @cart.update_status_to_sold
      user = @order.user
      if user.orders.count.eql?(1)
        user.send_reward_to_inviter unless user.inviter_code.blank?
      end
    elsif params[:status] == '11'
      status = "Cancelled"
      @cart.update_status_to_available
      current_user.update_attribute('credit', current_user.credit + @cart.cart_items.map(&:store_credit).sum)
    elsif params[:status] == '22'
      status = "Pending"
    else
      status = "Pending"
    end

    @order.update_attributes(
      payment_id: params[:tranID],
      status: status,
      charged_amount: params[:amount]
    )

    @order.order_information
    session[:cart_id] = nil
    redirect_to order_url(@order.id)
  end

  private

  def find_order
    @order = Order.find(params[:id].to_i)
  end

  def initialize_gateway
    ActiveMerchant::Billing::Base.mode = :test
    @paypal_gateway = ActiveMerchant::Billing::PaypalExpressGateway.new(
      :login     => PAYPAL_LOGIN,
      :password => PAYPAL_PASSWORD,
      :signature => PAYPAL_SIGNATURE
    )
  end

  def to_cent(money)
    money * 100
  end

end
