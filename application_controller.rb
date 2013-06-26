# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

class ApplicationController < ActionController::Base
  before_filter :check_cart, :sales, :checkout_timer, :get_size_charts, :get_about_hishop, :get_adv
  helper :all # include all helpers, all the time
  protect_from_forgery # See ActionController::RequestForgeryProtection for details
  
  rescue_from CanCan::AccessDenied do |exception|
    flash[:error] = exception.message
    redirect_to dashboard_url
  end

  def facebook
    # You need to implement the method below in your model
    @user = User.find_for_facebook_oauth(request.env["omniauth.auth"], current_user)
    if @user.persisted? && !@user.encrypted_password.blank?
      flash[:notice] = "Hi #{resource.first_name}, Welcome back !!"
      unless @cart.blank?
        @cart.cart_items.last.update_attribute('created_at', Time.zone.now) unless @cart.cart_items.empty?
      end
      sign_in_and_redirect @user, :event => :authentication
    elsif @user.persisted? && @user.encrypted_password.blank?
      session[:old_member] = true
      session["devise.facebook_data"] = request.env["omniauth.auth"]
      redirect_to new_user_session_url
    else
      session["devise.facebook_data"] = request.env["omniauth.auth"]
      session[:from_facebook] = true
      redirect_to new_user_session_url
    end
  end

  def states
    @states = State.all
  end

  def sales
    @active_sales = Sale.active.where(end_date: Time.zone.now)
    @active_sale_categories = SaleCategory.active
  end

  def get_size_charts
    @size_charts_all = SizeChart.all
  end

  def get_about_hishop
    @about_first = AboutHishop.first unless AboutHishop.first.nil?
  end

  def initialize_order_data
    @total_product_value = 0
    @total_weight = 0
    @total_hishop_cost = 0
    unless @cart.nil?
      @cart.cart_items.each do |cart_item|
        @total_product_value += cart_item.price * cart_item.amount
        @total_weight += cart_item.product.shipping_weight.to_i * cart_item.amount
        @total_hishop_cost += cart_item.amount * cart_item.product.hishop_cost
      end
    end
    cart_of_store_credit = if @cart.nil?
      0
    else
      @cart.cart_items.map(&:store_credit).sum
    end

    if session[:coupon_code_used]
      @shipping_cost = session[:shipping_cost]
      @price = @total_product_value.to_i - cart_of_store_credit.to_i
      @discount = Discount.get_discount(session[:total_price])
      if @discount.zero?
        @total_price = session[:total_price] - @discount_price.to_i
        @discount_price = 0
      else
        disc = @discount.to_f / 100
        @discount_price = (disc * session[:total_price]).to_i
        @total_price = session[:total_price] - @discount_price.to_i
      end
    else
      @price = @total_product_value.to_i - cart_of_store_credit.to_i
      @discount = Discount.get_discount(@price)
      if @discount.zero?
        @total_price = @price
        @discount_price = 0
      else
        disc = @discount.to_f / 100
        @discount_price = (disc * @price).to_i
        @total_price = @price - @discount_price.to_i
      end
    end
  end
  
  def clear_coupon_code_session
    if session[:coupon_code_used]
      coupon_codes_user = CouponCodesUser.where(user_id: current_user.id, coupon_code_id: session[:coupon_codes_user]).first
      unless coupon_codes_user.blank?
        coupon_codes_user.update_attributes(used_counter: coupon_codes_user.used_counter - 1)
      end
    end
    session[:coupon_codes_user] = nil
    session[:coupon_code_used] = nil
    session[:shipping_cost] = nil
    session[:total_price] = nil
    session[:coupon_code_id] = nil
  end


  def create_billing_and_delivery
    unless current_user.delivery_address
      @billing = BillingAddress.create!
      @delivery = DeliveryAddress.create!
      current_user.update_attributes(billing_address_id: @billing.id, delivery_address_id: @delivery.id)
    else
      @billing = current_user.billing_address
      @delivery = current_user.delivery_address
    end
  end

  def initialize_cart
    @cart = Cart.find_by_id(session[:cart_id]) || Cart.create
    session[:cart_id] = @cart.id unless @cart.blank?
  end
  
  private
  
  def get_adv
    session[:adv] = params[:adv] unless params[:adv].nil?
  end
  
  def redirect_to_root_url
    if Rails.env == "production" && !params[:controller].include?('admin')
      redirect_to root_url
    end
  end

  def check_cart
    @cart = Cart.find_by_id(session[:cart_id])
    session[:cart_id] = @cart.id unless @cart.blank?
    unless user_signed_in?
      @user_register = User.new
    end
  end
  
  def current_ability
    @current_ability ||= Ability.new(current_admin_user)
  end

  def checkout_timer
    unless @cart.blank?
      unless @cart.cart_items.empty?
        @cart.cart_items.last.update_attribute('created_at', Time.zone.now) if session[:checkout_timer]
        session[:checkout_timer] = nil
        session[:from_delivery] = nil
      end
    end
  end
end
