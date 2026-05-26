# frozen_string_literal: true

# VMVTech Plus addition — Phase 3 unblock.
#
# POST /api/templates/pdf
#
# Accepts a PDF and creates a Template with auto-detected signature/text
# fields. Mirrors Templates::CreateAttachments pipeline used by the admin UI
# (TemplatesUploadsController). Returns JSON compatible with the Pro
# `/api/templates/html` shape so callers can swap endpoints without code
# change to downstream submission creation.
#
# Two body formats accepted:
#
#   1. JSON: { name, folder_name, pdf_base64, filename, fields }
#      - pdf_base64: base64-encoded PDF bytes (recommended path)
#      - filename: optional, defaults to "document.pdf"
#      - fields: optional array (forwarded to template.fields)
#
#   2. JSON: { name, folder_name, url, filename }
#      - url: fetched server-side via DownloadUtils
#
# We use JSON (not multipart) deliberately — the api namespace has
# `defaults: { format: :json }` which conflicts with multipart parsing.
# Base64 inflates payload ~33% but eliminates a class of bugs and makes
# the endpoint trivial to call from Next.js / fetch / etc.

module Api
  class TemplatesPdfController < ApiBaseController
    skip_authorization_check

    DEFAULT_SUBMITTER_ROLE = 'Client'
    DEFAULT_SIGNATURE_FIELD_AREA = { 'x' => 0.15, 'y' => 0.78, 'w' => 0.4, 'h' => 0.07 }.freeze
    MAX_PDF_BYTES = 50 * 1024 * 1024 # 50 MB safety cap

    def create
      pdf_param = extract_pdf_param!

      template = Template.new(
        account: current_account,
        author: current_user,
        folder: TemplateFolders.find_or_create_by_name(current_user, params[:folder_name]),
        name: params[:name].presence || File.basename(pdf_param[:files].first.original_filename, '.*'),
      )
      Templates.maybe_assign_access(template) if Templates.respond_to?(:maybe_assign_access)
      template.save!

      documents, = Templates::CreateAttachments.call(template, pdf_param, extract_fields: true)
      schema = documents.map { |doc| { 'attachment_uuid' => doc.uuid, 'name' => doc.filename.base } }

      template.fields = Templates::ProcessDocument.normalize_attachment_fields(template, documents) if template.fields.blank?
      apply_caller_fields!(template, documents) if params[:fields].present? && template.fields.blank?
      ensure_default_signature_field!(template, documents) if template.fields.blank?

      template.update!(schema: schema)

      WebhookUrls.enqueue_events(template, 'template.created') if defined?(WebhookUrls)
      SearchEntries.enqueue_reindex(template) if defined?(SearchEntries)

      render json: serialize(template), status: :created
    rescue Templates::CreateAttachments::PdfEncrypted
      render json: { error: 'PDF is encrypted; decrypt before upload' }, status: :unprocessable_content
    rescue ActionController::ParameterMissing => e
      render json: { error: e.message }, status: :unprocessable_content
    rescue StandardError => e
      Rollbar.error(e) if defined?(Rollbar)
      raise if Rails.env.local?

      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def extract_pdf_param!
      if params[:pdf_base64].present?
        bytes = Base64.decode64(params[:pdf_base64])
        raise ActionController::ParameterMissing, 'pdf too large' if bytes.bytesize > MAX_PDF_BYTES
        raise ActionController::ParameterMissing, 'pdf_base64 does not decode to a PDF' unless bytes.start_with?('%PDF-')

        tempfile = Tempfile.new(['template-', '.pdf'])
        tempfile.binmode
        tempfile.write(bytes)
        tempfile.rewind

        filename = params[:filename].presence || 'document.pdf'
        file = ActionDispatch::Http::UploadedFile.new(
          tempfile: tempfile, filename: filename, type: 'application/pdf'
        )

        return { files: [file] }
      end

      if params[:url].present?
        tempfile = Tempfile.new
        tempfile.binmode
        tempfile.write(DownloadUtils.call(params[:url], validate: true).body)
        tempfile.rewind

        filename = if params[:filename].present?
                     URI.decode_www_form_component(params[:filename])
                   else
                     File.basename(URI.decode_www_form_component(params[:url]))
                   end

        file = ActionDispatch::Http::UploadedFile.new(
          tempfile: tempfile, filename: filename, type: Marcel::MimeType.for(tempfile)
        )

        return { files: [file] }
      end

      raise ActionController::ParameterMissing, 'pdf_base64 or url required'
    end

    def apply_caller_fields!(template, _documents)
      fields = params[:fields].respond_to?(:to_unsafe_h) ? params[:fields] : params[:fields]
      return unless fields.is_a?(Array) || fields.respond_to?(:to_a)

      template.fields = Array.wrap(fields).map(&:to_h)
    end

    def ensure_default_signature_field!(template, documents)
      submitter_uuid = SecureRandom.uuid
      doc = documents.last
      doc_uuid = doc.uuid
      pages = doc.metadata.dig('pdf', 'number_of_pages').to_i
      pages = 1 if pages.zero?

      template.submitters = [{ 'name' => DEFAULT_SUBMITTER_ROLE, 'uuid' => submitter_uuid }]
      template.fields = [{
        'uuid' => SecureRandom.uuid,
        'submitter_uuid' => submitter_uuid,
        'name' => 'Signature',
        'type' => 'signature',
        'required' => true,
        'areas' => [DEFAULT_SIGNATURE_FIELD_AREA.merge('attachment_uuid' => doc_uuid, 'page' => pages - 1)],
      }]
    end

    def serialize(template)
      {
        id: template.id,
        slug: template.slug,
        name: template.name,
        schema: template.schema,
        submitters: template.submitters,
        fields: template.fields,
        author_id: template.author_id,
        account_id: template.account_id,
        folder_id: template.folder_id,
        created_at: template.created_at,
        updated_at: template.updated_at,
      }
    end
  end
end
