# == Schema Information
#
# Table name: orders
#
#  id                  :integer(4)      not null, primary key
#  cart_id             :integer(4)
#  user_id             :integer(4)
#  total_weight        :float           default(0.0)
#  total_product_value :float           default(0.0)
#  total_shipping_cost :float           default(0.0)
#  sub_total           :float           default(0.0)
#  status              :string(255)     default("pending")
#  slug                :string(255)
#  created_at          :datetime        not null
#  updated_at          :datetime        not null
#  charged_amount      :float
#  raw_post            :text
#  transid             :string(255)
#  payment_id          :integer(4)      default(2)
#  billing_address_id  :integer(4)
#  delivery_address_id :integer(4)
#  payment_gateway     :string(255)
#  comment             :text
#  coupon_code_id      :integer(4)
#

class Order < ActiveRecord::Base
  belongs_to :billing_address
  belongs_to :delivery_address
  belongs_to :user
  belongs_to :cart
  belongs_to :coupon_code
  
  validates :user_id, :cart_id, presence: true

  def send_order_details
    OrderMailer.delay.send_order_details(self, self)
  end

  def order_information
    recipients = []
    recipients << 'sales@hishop.my'
    recipients << self.user.email

    recipients.each do |recipient|
      if recipient.eql?('sales@hishop.my')
        OrderMailer.delay.order_information(recipient, self)
      else
        OrderMailer.delay.order_information(self, self)
      end
    end
  end

  def self.change_status_order
    orders = Order.where(["updated_at < ? AND status = ?", 1.hour.ago, 'Pending'])
    unless orders.empty?
      with_lock do
        orders.each do |order|
          if order.cart.cart_items.empty?
            order.update_attribute('status', 'Cancelled')
          else
            if order.cart.cart_items.last.created_at < 15.minutes.ago
              order.update_attribute('status', 'Cancelled')
              order.cart.update_status_to_available
            end
          end
        end
      end
    end
  end

  def self.check_status_order_to_molpay
    require 'mechanize'
    orders = Order.where(["updated_at < ? AND payment_id != ? AND status = ?", 20.hours.ago, 2, 'Cancelled'])
    orders.each do |order|
      skey = Digest::MD5.hexdigest("#{order.id}#{MOLPAY_MERCHANT_ID}#{MOLPAY_VERIFY_KEY}#{order.sub_total}")
      a = Mechanize.new
      page = a.get("https://www.onlinepayment.com.my/NBepay/query/q_by_oid.php?amount=#{order.sub_total}&oID=#{order.id}&domain=#{MOLPAY_MERCHANT_ID}&skey=#{skey}")
      unless page.body.include?("Error")
        result = Hash[*page.body.split(' ')]
        if result["StatName:"].eql?("settled")
          order.update_attribute('status', 'Confirmation')
          out_of_stock = []
          orderlist = []
          order.cart.cart_items.each do |cart_item|
            ab = cart_item.details_and_quantity.available_balance
            ns = cart_item.details_and_quantity.number_sold
            if ab < cart_item.amount
              out_of_stock << cart_item
            else
              orderlist << cart_item
              cart_item.details_and_quantity.update_attribute('number_sold', ns + cart_item.amount)
            end
          end
          OrderMailer.delay.order_delay_information('sales@hishop.my', order, out_of_stock, orderlist)
        end
      end
    end
  end
end