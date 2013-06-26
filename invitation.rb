# == Schema Information
#
# Table name: invitations
#
#  id         :integer(4)      not null, primary key
#  user_id    :integer(4)
#  email      :string(255)
#  status     :string(255)     default("pending")
#  mail_sent  :boolean(1)      default(FALSE)
#  created_at :datetime        not null
#  updated_at :datetime        not null
#

class Invitation < ActiveRecord::Base
  belongs_to :user
  validates_uniqueness_of :email, on: :create, message: "has been invited", scope: :user_id
  validates :email, format: { with: /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i, on: :create }
  attr_accessor :emails, :message

  after_create :send_invitation
  cattr_accessor :message

  def pending?
    self.status == "pending"
  end

  def is_available?
    (self.updated_at + 3.days) <= Time.now && self.pending?
  end

  def send_invitation
    InvitationMailer.delay.invitation(self, Invitation.message) if status.eql?("pending")
  end

  def resend_invitation
    InvitationMailer.delay.invitation(self, "")
    self.update_attribute('updated_at', Time.now)
  end

  def self.resend_all_invitation
    invitations = self.where(["status = 'pending' AND updated_at <= ?", 3.days.ago])
    invitations.each do |invitation|
      InvitationMailer.delay.invitation(invitation, "")
      invitation.update_attribute('updated_at', Time.now)
    end
    invitations
  end
  
  def self.resend_all_by_admin
    invitations = self.pending
    invitations.each do |invitation|
      InvitationMailer.delay.invitation(invitation, "")
      invitation.update_attribute('mail_sent', invitation.mail_sent?)
    end
  end

  def self.create_and_send_coupon_promo(receiver)
    promo = CouponCode.where(specific_members: receiver)
    user_code = receiver.split('@').first.parameterize("")
    mimi = MadMimi.new(MADMIMI_EMAIL, MADMIMI_API_KEY)
    if promo.blank?
      coupon = CouponCode.create(code: user_code + rand(7).to_s + "hishop", coupon_type: "percentage", value: 5, start_date: Time.zone.now,
        end_date: 1.week.from_now, category: "Coupon", number_of_uses: 1, free_shipping: 0, minimum_purchase: 1, specific_members: receiver)

      mimi.add_to_list(receiver, "Mail Promo")
      InvitationMailer.delay.send_coupon_promo(receiver, coupon)

      return "Thank you ! Check your email to enjoy your 5% extra discount coupon."
    else
      has_promo = []
      promo.map { |p| has_promo << p.code.include?(user_code) }
      if has_promo.include?(false)
        coupon = CouponCode.create(code: user_code + rand(7).to_s + "hishop", coupon_type: "percentage", value: 5, start_date: Time.zone.now,
          end_date: 1.week.from_now, category: "Coupon", number_of_uses: 1, free_shipping: 0, minimum_purchase: 1, specific_members: receiver)

        mimi.add_to_list(receiver, "Mail Promo")
        InvitationMailer.delay.send_coupon_promo(receiver, coupon)
        return "Thank you ! Check your email to enjoy your 5% extra discount coupon."
      else
        return "Sorry you already get coupon promo..!!"
      end
    end
  end
end

