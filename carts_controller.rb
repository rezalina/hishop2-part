class CartsController < InheritedResources::Base
  before_filter :initialize_cart
  skip_before_filter :checkout_timer, only: [:basket, :calculate_shipping_cost]
  before_filter :validate_details_and_quantity, only: [:add]
  before_filter :validate_quantity, only: [:update]
  before_filter :update_last_product, only: [:basket]
  before_filter :initialize_order_data, only: [:basket, :calculate_shipping_cost]
  actions :add
  nested_belongs_to :sale, :product

  def add
    session[:show_cart] = false
    cart_item = CartItem.where(cart_id: @cart.id, details_and_quantity_id: @details_and_quantity.id).first
    if cart_item.nil?
      success = @cart.cart_items.create({product_id: parent.id, details_and_quantity_id: @details_and_quantity.id, price: parent.hishop_price, amount: params[:quantity]})
      cart_item = @cart.cart_items.last
      current_user.credit!(params[:quantity].to_i, cart_item) if user_signed_in?
    else
      success = cart_item.update_attribute(:amount, cart_item.amount + params[:quantity].to_i)
    end

    if success || success.errors.empty?
      session[:show_cart] = true
      cart_item.add_item_to_cart(params[:quantity].to_i)
      clear_coupon_code_session if user_signed_in?
      redirect_to sale_product_path(parent.sale, parent), notice: "#{parent.product_name.titleize} was successfully added to your shopping cart"
    end
  end

  def my_cart
    @cart_items = CartItem.where(cart_id: @cart)

    render template: "carts/show"
  end

  def basket
    if @cart.cart_items.empty?
      redirect_to sales_url, notice: "Oops Sorry, your checkout timer is up"
    else
      session[:checkout_timer] = true
      @delivery_address = current_user.delivery_address
      @billing_address = current_user.billing_address
    end
  end

  def update
    available_balance = @details_and_quantity.available_balance
    pending_quantity = @details_and_quantity.pending_quantity
    total_available_balance = (available_balance + @cart_item.amount) - params["quantity_#{params[:id]}"].to_i
    total_pending_quantity = (pending_quantity - @cart_item.amount) + params["quantity_#{params[:id]}"].to_i
    @details_and_quantity.update_attributes(available_balance: total_available_balance, pending_quantity: total_pending_quantity)
    @cart_item.update_attribute("amount", params["quantity_#{params[:id]}"].to_i)
    session[:show_cart] = true
    redirect_to request.env["HTTP_REFERER"], notice: "#{@cart_item.product.product_name.titleize} was successfully updated in your cart"
  end

  def calculate_shipping_cost
    if user_signed_in?
      @goto = params[:goto]
      current_cart = Cart.find(params[:cart_id])
      if current_cart.cart_items.empty?
        redirect_to sales_path, notice: "Oops Sorry, your checkout timer is up"
      else
        region = Region.find(params[:region_id])
        @value = current_user.shipping_cost(region, current_cart.cart_items, @total_price)
      end
    else
      render js: "window.location = '/sales'"
    end
  end

  def destroy
    if @cart.order && @cart.cart_items.count.eql?(1)
      @cart = @cart.change_order_status_and_create_new
      session[:cart_id] = @cart.id
    else
      cart_item = CartItem.find(params[:id])
      msg = "#{cart_item.product.product_name.titleize} was successfully deleted from your cart"
      cart_item.delete_cart_item(current_user)
    end

    clear_coupon_code_session if user_signed_in?
    session[:show_cart] = true
    if request.env["HTTP_REFERER"] =~ /checkout/
      redirect_to sales_url, notice: msg
    else
      redirect_to request.env["HTTP_REFERER"], notice: msg
    end
  end

  def delete_cart_items
    if @cart.order
      @cart.order.update_attributes(status: 'Cancelled', coupon_code_id: 0) if @cart.order.status.eql?("Pending")
      @cart.update_status_to_available unless @cart.cart_items.empty?
      @cart = Cart.create
      session[:cart_id] = @cart.id
    else
      @cart = Cart.find(params[:id])
      unless @cart.cart_items.empty?
        @cart.update_status_to_available
        if user_signed_in?
          credit = current_user.credit + @cart.cart_items.map(&:store_credit).sum
          current_user.update_attribute('credit', credit)
        end
        @cart.cart_items.destroy_all
      end
    end

    clear_coupon_code_session if user_signed_in?
    if request.xhr?
      render nothing: true
    else
      if request.env["HTTP_REFERER"] =~ /checkout/
        redirect_to sales_path, notice: "Sorry, All items has been deleted because your shopping cart timer is up"
      else
        redirect_to request.env["HTTP_REFERER"], notice: "All items has been deleted because your shopping cart timer is up"
      end
    end
  end

  def cart_items_notice
    if @cart.nil?
      redirect_to sales_url
    elsif @cart.cart_items.empty?
      redirect_to sales_url
    else
      redirect_to request.env["HTTP_REFERER"], notice: "Your cart items will remain in your shopping cart for another 5 min before it is made available to other members again. Click on checkout and get it now before it is too late ! :)"
    end
  end

  def ajax_checkout
    @item = params[:item]

    render layout: false
  end

  def send_feedback
    page = params[:page]

    begin
      AdminMailer.contact_us(params[:feedback][:email], params[:feedback][:reason], params[:feedback][:message], params[:feedback][:name]).deliver
      notice = "Your message was successfull sent to contact@hishop.my"
    rescue
      notice = "Your message failed to send to contact@hishop.my"
    end

    redirect_to page, notice: notice
  end

  protected

  def validate_details_and_quantity
    @details_and_quantity = parent.details_and_quantities.find(params[:details_and_quantity_id].to_i)
    if !params[:details_and_quantity_id].to_i || @details_and_quantity.nil?
      redirect_to request.env["HTTP_REFERER"], notice: "Sorry, but that size isn't available"
    elsif @details_and_quantity.available_balance < (params[:quantity].to_i)
      redirect_to request.env["HTTP_REFERER"], notice: "Sorry, only #{@details_and_quantity.available_balance} quantity available for #{@details_and_quantity.name}"
    end
  end

  def validate_quantity
    @cart_item = CartItem.find(params[:id])
    @details_and_quantity = @cart_item.details_and_quantity
    session[:show_cart] = true
    notice = if !params[:details_and_quantity_id].to_i || @details_and_quantity.nil?
      "Oops.. Sorry, but that size/color isn't available"
    elsif @details_and_quantity.available_balance.zero?
      "Oops.. Sorry, #{@cart_item.product.product_name.titleize} is out of stock"
    elsif @details_and_quantity.available_balance < params["quantity_#{params[:id]}"].to_i
      "Oops.. Sorry, you can only add #{@details_and_quantity.available_balance} for #{@cart_item.product.product_name.titleize}"
    end
    redirect_to request.env["HTTP_REFERER"], notice: notice
  end

  def update_last_product
    if @cart.nil?
      redirect_to sales_url
    elsif @cart.cart_items.empty?
      redirect_to sales_url, notice: "Oops..Sorry, your checkout timer is up"
    else
      session[:total_price] = @cart.grand_total unless session[:coupon_code_used]
      unless session[:from_delivery]
        @cart.cart_items.last.update_attribute('created_at', Time.zone.now)
      end
    end
  end

end
