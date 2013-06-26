# == Schema Information
#
# Table name: carts
#
#  id                  :integer(4)      not null, primary key
#  created_at          :datetime        not null
#  updated_at          :datetime        not null
#  total_price         :float           default(0.0)
#  total_price_product :float           default(0.0)
#  shipping_cost       :float           default(0.0)
#

class Cart < ActiveRecord::Base
  attr_accessor :total_price_product, :shipping_cost, :total_price
  
  with_options dependent: :destroy do |cart|
    cart.has_many :cart_items
    cart.has_many :products, through: :cart_items
    cart.has_one :order
  end

  def saving_cost
    self.cart_items.map(&:product).map(&:original_price).sum - self.cart_items.map(&:price).sum
  end

  def grand_total
    total = []
    self.cart_items.map{|cart_item| total << cart_item.price * cart_item.amount }
    total.sum
  end

  def update_status_to_sold
    self.with_lock do
      self.cart_items.each do |cart_item|
        ns = cart_item.details_and_quantity.number_sold
        pq = cart_item.details_and_quantity.pending_quantity
        pending_quantity = pq.to_i - cart_item.amount.to_i
        if pq > 0 && pending_quantity >= 0
          cart_item.details_and_quantity.update_attributes(number_sold: ns + cart_item.amount, pending_quantity: pending_quantity)
        end
      end
    end
  end

  def update_status_to_available
    self.with_lock do
      self.cart_items.each do|cart_item|
        ab = cart_item.details_and_quantity.available_balance
        pq = cart_item.details_and_quantity.pending_quantity
        pending_quantity = pq.to_i - cart_item.amount.to_i
        if pq > 0 && pending_quantity >= 0
          cart_item.details_and_quantity.update_attributes(available_balance: ab.to_i + cart_item.amount.to_i, pending_quantity: pending_quantity)
        end
      end
    end
  end

  def change_order_status_and_create_new
    self.with_lock do
      self.order.update_attributes(status: 'Cancelled', coupon_code_id: 0) if self.order.status.eql?("Pending")
      self.update_status_to_available
    end
    
    Cart.new
  end

  def self.clear_cart
    carts = where(['created_at < ?', 3.days.ago])
    carts.map{|cart| cart.destroy if cart.cart_items.empty? && cart.order.blank?}
  end

end

