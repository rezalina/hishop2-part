# == Schema Information
#
# Table name: cart_items
#
#  id                      :integer(4)      not null, primary key
#  cart_id                 :integer(4)
#  product_id              :integer(4)
#  details_and_quantity_id :integer(4)
#  price                   :float
#  amount                  :integer(4)
#  created_at              :datetime        not null
#  updated_at              :datetime        not null
#  store_credit            :float           default(0.0)
#

class CartItem < ActiveRecord::Base
  belongs_to :cart
  belongs_to :product
  belongs_to :details_and_quantity

  def expired_in
    (self.created_at + 15.minutes).to_i - Time.zone.now.to_i
  end

  def total
    self.price * self.amount
  end

  def self.clear_cart_item
    cart_items = where(['created_at < ?', 1.hour.ago])
    self.with_lock do
      cart_items.each do |cart_item|
        if cart_item.cart.order.nil?
          ab = cart_item.details_and_quantity.available_balance
          pq = cart_item.details_and_quantity.pending_quantity
          pending_quantity = pq.to_i - cart_item.amount.to_i
          if pq > 0 && pending_quantity >= 0
            cart_item.details_and_quantity.update_attributes(available_balance: ab.to_i + cart_item.amount.to_i, pending_quantity: pending_quantity)
          end
          cart_item.destroy
        end
      end
    end
  end

  def delete_cart_item(user)
    ab = self.details_and_quantity.available_balance
    pq = self.details_and_quantity.pending_quantity
    pending_quantity = pq.to_i - self.amount.to_i
    
    self.with_lock do
      user.update_attribute('credit', user.credit + self.store_credit.to_i) unless user.blank?
      if pq > 0 && pending_quantity >= 0
        self.details_and_quantity.update_attributes(available_balance: ab.to_i + self.amount.to_i, pending_quantity: pending_quantity)
      end
      self.destroy
    end
  end

  def add_item_to_cart(quantity)
    self.with_lock do
      ab = self.details_and_quantity.available_balance
      pq = self.details_and_quantity.pending_quantity
      self.details_and_quantity.update_attributes(available_balance: ab - quantity.to_i, pending_quantity: pq + quantity.to_i)
    end
  end
end

