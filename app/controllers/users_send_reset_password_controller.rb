# frozen_string_literal: true

class UsersSendResetPasswordController < ApplicationController
  load_and_authorize_resource :user

  LIMIT_DURATION = 10.minutes

  def update
    authorize!(:manage, @user)

    if rate_limited?
      redirect_back fallback_location: settings_users_path, notice: I18n.t('email_has_been_sent_already')
    else
      @user.send_reset_password_instructions

      redirect_back fallback_location: settings_users_path,
                    notice: I18n.t('an_email_with_password_reset_instructions_has_been_sent')
    end
  end

  private

  # Rate limit only applies when a recent email was sent AND it's still valid.
  # If the invitation token is already expired (never accepted + older than
  # Devise.reset_password_within), allow immediate resend so admins can recover
  # stuck invitations without waiting.
  def rate_limited?
    return false if @user.reset_password_sent_at.blank?
    return false if @user.invitation_status == :expired

    @user.reset_password_sent_at > LIMIT_DURATION.ago
  end
end
