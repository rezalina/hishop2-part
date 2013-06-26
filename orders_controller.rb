class OrdersController < InheritedResources::Base
  before_filter :initialize_cart
  skip_before_filter :checkout_timer
  before_filter :authenticate_user!
  before_filter :find_address, only: :new
  actions :index, :new, :create, :show
  before_filter :initialize_order_data, only: [:create, :apply_coupon_code, :new]

  def index
    @orders = current_user.orders
  end

  def create
    if @cart.cart_items.empty?
      redirect_to sales_url, notice: "Oops Sorry, your checkout timer is up"
    else
      @billing_address = set_default_billing_address_for_user(params[:billing_address], current_user)
      @shipping_address = set_default_shipping_address_for_user(params[:shipping_address], current_user)
      if @total_price.zero? && session[:shipping_cost].zero?
        free_order
        @cart.update_status_to_sold
        session[:cart_id] = nil
        @order.order_information
        redirect_to order_url(@order.id)
      else
        disc = @discount.to_f / 100
        @order = Order.where(cart_id: @cart.id).first_or_create!(user_id: current_user.id)
        @order.update_attributes(total_weight: @total_weight.to_i,
          total_product_value: @total_product_value.to_i,
          total_hishop_cost: @total_hishop_cost.to_i,
          total_shipping_cost: session[:shipping_cost].to_i,
          discount_price: disc * @total_product_value.to_i,
          sub_total: @total_price.to_f.ceil + session[:shipping_cost].to_f.ceil,
          billing_address_id: (@billing_address.id rescue nil),
          delivery_address_id: (@shipping_address.id rescue nil),
          payment_gateway: params[:payment_method],
          comment: params[:comment],
          status: 'Pending',
          coupon_code_id: session[:coupon_code_id]
        )
        unless session[:utm_source].blank? and session[:utm_medium].blank? and session[:utm_campaign].blank?
          @order.update_attributes(
            utm_source: session[:utm_source],
            utm_medium: session[:utm_medium],
            utm_campaign: session[:utm_campaign]
          )
        end

        session[:billing] = nil
        session[:delivery] = nil
        session[:from_delivery] = nil
        if @order.payment_gateway.eql?('paypal')
          redirect_to pay_with_paypal_payment_url(@order.id)
        else
          redirect_to pay_with_molpay_payment_url(@order.id)
        end
      end
    end
  end

  def free_order
    @order = Order.where(cart_id: @cart.id).first_or_create!(user_id: current_user.id)
    @order.update_attributes(total_weight: @total_weight.to_i,
      total_product_value: @total_product_value.to_i,
      total_hishop_cost: @total_hishop_cost.to_i,
      total_shipping_cost: session[:shipping_cost].to_i,
      sub_total: @total_price.to_f.ceil + session[:shipping_cost].to_f.ceil,
      charged_amount: @total_price.to_f.ceil + session[:shipping_cost].to_f.ceil,
      billing_address_id: (@billing_address.id rescue nil),
      delivery_address_id: (@shipping_address.id rescue nil),
      payment_gateway: "--",
      comment: params[:comment],
      status: 'Confirmed',
      coupon_code_id: session[:coupon_code_id]
    )
    unless session[:utm_source].blank? and session[:utm_medium].blank? and session[:utm_campaign].blank?
      @order.update_attributes(
        utm_source: session[:utm_source],
        utm_medium: session[:utm_medium],
        utm_campaign: session[:utm_campaign]
      )
    end

    session[:billing] = nil
    session[:delivery] = nil
    session[:from_delivery] = nil
  end

  def show
    @order = Order.find(params[:id].to_i)
  end

  def find_address
    @billing = BillingAddress.find(session[:billing].id)
    @delivery = DeliveryAddress.find(session[:delivery].id)
  end

  def apply_coupon_code
    if request.xhr?
      @coupon = CouponCode.find_by_code(params[:id])
      @shipping_cost = session[:shipping_cost]
        @status = false
      @message = if @coupon.blank?
        " Can't find Coupon with '#{params[:id]}' code."
      else
        if !@coupon.is_valid?
          "Coupon with '#{params[:id]}' code has expired."
        elsif @coupon.over_limit?(current_user.id)
          "Coupon with '#{params[:id]}' code is over limit"
        elsif @total_price < @coupon.minimum_purchase
          "Coupon can't be used because your sub total is lower than #{@coupon.minimum_purchase} "
        else
          members = @coupon.specific_members.nil? ? " " : @coupon.specific_members
          products = @coupon.specific_products.nil? ? " " : @coupon.specific_products
          if !@coupon.specific_members.blank? && !members.include?(current_user.email)
            "Coupon with '#{params[:id]}' code is not for you"
          elsif !@coupon.specific_products.blank? && !@coupon.has_specific_products?(products, @cart.cart_items)
            "Coupon with '#{params[:id]}' code is not for some products in your cart"
          else
            @users_used = @coupon.users.count
            coupon_user

            if @coupon.as_gift_certifcate?
              coupon_as_gift_certifcate
            elsif @coupon.as_coupon?
              coupon_as_coupon
            else
              "Coupon with '#{params[:id]}' code have not valid category."
            end
          end
        end
      end
      respond_to do |format|
        format.js
      end
    else
      redirect_to root_url
    end
  end

  private

  def coupon_as_gift_certifcate
    if @users_used > @coupon.number_of_uses
      @message = "Coupon with '#{params[:id]}' code has been used up."
      @status = false
    else
      shipping_cost_process

      if @coupon.coupon_type.eql?('percentage')
        percentage_coupon
      elsif @coupon.coupon_type.eql?('absolute')
        absolute_coupon
      end

      @coupon_user.blank? ? create_coupon_code_user :  update_coupon_code_user
    end
  end

  def coupon_as_coupon
    unless @coupon_user.blank?
      if @coupon_user.used_counter >= @coupon.number_of_uses
        @message = " You have no more oportunity for use this coupon."
        @status = false
      else
        coupon_as_coupon_process
        update_coupon_code_user
      end
    else
      coupon_as_coupon_process
      create_coupon_code_user
    end
  end

  def coupon_as_coupon_process
    shipping_cost_process

    if @coupon.coupon_type.eql?('percentage')
      percentage_coupon
    elsif @coupon.coupon_type.eql?('absolute')
      absolute_coupon
    end
  end

  def percentage_coupon
    session[:total_price] = @coupon.get_price_for_specific_products_in_precentage_coupon(@price, @cart.cart_items)
    @discount = Discount.get_discount(session[:total_price])
    if @discount.zero?
      @total_price = session[:total_price] + session[:shipping_cost]
      @discount_price = 0
    else
      disc = @discount.to_f / 100
      @discount_price = (disc * session[:total_price]).to_i
      @total_price = session[:total_price] - @discount_price.to_i + session[:shipping_cost]
    end
    @status = true

    if @coupon.free_shipping
      @message = if @coupon.specific_products.blank?
        "You got free shipping and #{@coupon.value}% from sub total."
      else
        "You got free shipping and #{@coupon.value}% from some products in your cart"
      end
    else
      @message = if @coupon.specific_products.blank?
        "You got #{@coupon.value}% from sub total."
      else
        "You got #{@coupon.value}% from some products in your cart"
      end
    end

    session[:coupon_code_used] = true
    session[:coupon_code_id] = @coupon.id
  end

  def absolute_coupon
    session[:total_price] = @coupon.get_price_for_specific_products_in_absolute_coupon(@price, @cart.cart_items)
    @discount = Discount.get_discount(session[:total_price])
    if @discount.zero?
      @total_price = session[:total_price] + session[:shipping_cost]
      @discount_price = 0
    else
      disc = @discount.to_f / 100
      @discount_price = (disc * session[:total_price]).to_i
      @total_price = session[:total_price] - @discount_price.to_i
    end
    @status = true

    if @coupon.free_shipping
      @message = if @coupon.specific_products.blank?
        "You got free shipping and RM#{@coupon.value} from sub total."
      else
        "You got free shipping and RM#{@coupon.value} from some products in your cart"
      end
    else
      @message = if @coupon.specific_products.blank?
        "You got RM#{@coupon.value} from sub total."
      else
        "You got RM#{@coupon.value} from some products in your cart"
      end
    end

    session[:coupon_code_used] = true
    session[:coupon_code_id] = @coupon.id
  end

  def shipping_cost_process
    if @coupon.free_shipping?
      session[:shipping_cost] = 0
    end
  end

  def coupon_user
    @coupon_user = CouponCodesUser.where(user_id: current_user.id, coupon_code_id: @coupon.id).first
    session[:coupon_codes_user] = @coupon_user.id unless @coupon_user.blank?
  end

  def create_coupon_code_user
    @coupon_user = CouponCodesUser.create(:coupon_code_id => @coupon.id, :user_id => current_user.id)
    session[:coupon_codes_user] = @coupon_user.id unless @coupon_user.blank?
  end

  def update_coupon_code_user
    @coupon_user.update_attributes(used_counter:  @coupon_user.used_counter + 1)
  end

  def create_billing_address(billing)
    billing_address = BillingAddress.new
    billing_address.build_address(billing)
    billing_address.save ? billing_address : nil
  end

  def create_shipping_address(shipping)
    shipping_address = DeliveryAddress.new
    shipping_address.build_address(shipping)
    shipping_address.save ? shipping_address : nil
  end

  def set_default_shipping_address_for_user(shipping, user)
    if user.delivery_address.blank?
      delivery_address = DeliveryAddress.new
      delivery_address.build_address(shipping)
      if delivery_address.save
        user.update_attribute(:delivery_address_id, delivery_address.id )
      end

      user.delivery_address
    else
      user.delivery_address.address.update_attributes(shipping)

      user.delivery_address
    end
  end

  def set_default_billing_address_for_user(billing, user)
    if user.billing_address.blank?
      billing_address = BillingAddress.new
      billing_address.build_address(billing)
      if billing_address.save
        user.update_attribute(:billing_address_id, billing_address.id )
      end

      user.billing_address
    else
      user.billing_address.address.update_attributes(billing)

      user.billing_address
    end
  end

end
