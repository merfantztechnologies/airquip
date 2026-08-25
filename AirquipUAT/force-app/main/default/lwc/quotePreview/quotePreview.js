import { LightningElement, api, track, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import generateQuoteDocument from '@salesforce/apex/QuoteDocumentController.generateQuoteDocument';
import getFromAddresses from '@salesforce/apex/QuoteEmailService.getFromAddresses';
import searchEmails from '@salesforce/apex/QuoteEmailService.searchEmails';
import sendQuoteEmail from '@salesforce/apex/QuoteEmailService.sendQuoteEmail';
import getQuoteEmailTemplate from '@salesforce/apex/QuoteEmailService.getQuoteEmailTemplate';
import getQuoteDocumentDetails from '@salesforce/apex/QuoteDocumentController.getQuoteDocumentDetails';
import getLatestQuoteFile from '@salesforce/apex/QuoteEmailService.getLatestQuoteFile';
import USER_ID from '@salesforce/user/Id';
import QUOTE_EMAIL_FIELD from '@salesforce/schema/Quote.Email';
import QUOTE_DESCRIPTION_FIELD from '@salesforce/schema/Quote.Scope_of_Work__c';

// ── Format constants ──────────────────────────────────────────────────────────
const FORMAT_QUOTE_PREVIEW = 'QuotePreview';
const FORMAT_QUOTE_SUMMARY = 'QuoteSummaryFormatPreview';

const FORMAT_META = {
    [FORMAT_QUOTE_PREVIEW]: {
        label : 'Quote Preview',
    
        icon  : 'doctype:pdf'
    },
    [FORMAT_QUOTE_SUMMARY]: {
        label : 'Quote Summary',
        
        icon  : 'utility:description'
    }
};

export default class PdfEmailComposer extends LightningElement {

    @api recordId;
    @track currentuserid = USER_ID;

    // ── Loading states ────────────────────────────────────────────────────────
    @track isLoading               = false;
    @track isLoadingforSaveandsend = false;
    @track attachments             = [];

    // ── Screen visibility ─────────────────────────────────────────────────────
    // showFormatPicker is only opened after we check Description in the wire
    @track showFormatPicker  = false;
    @track showPdfModal      = false;
    @track showEmailComposer = false;

    // ── Scope of work flag (set by wire) ──────────────────────────────────────
    @track hasScopeOfWork = false;

    // ── Format selection ──────────────────────────────────────────────────────
    @track selectedFormat  = FORMAT_QUOTE_SUMMARY;  // default
    @track isDropdownOpen  = false;

    // ── Wire: check Quote.Description AND pre-fill email ─────────────────────
    @wire(getRecord, {
        recordId : '$recordId',
        fields   : [QUOTE_EMAIL_FIELD, QUOTE_DESCRIPTION_FIELD]
    })
    wiredQuote({ error, data }) {
        if (data) {
            // Pre-fill To email
            const email = getFieldValue(data, QUOTE_EMAIL_FIELD);
            if (email && !this.toList.includes(email)) {
                this.toList = [email];
                this.toInput = '';
            }

            // Check scope of work
            const description = getFieldValue(data, QUOTE_DESCRIPTION_FIELD);
            this.hasScopeOfWork = !!description && description.trim().length > 0;

            // ── Routing logic ──────────────────────────────────────────────
            if (this.hasScopeOfWork) {
                // Show format picker so user can choose template
                this.showFormatPicker = true;
            } else {
                // Skip picker — go straight to PDF with QuotePreview
                this.selectedFormat = FORMAT_QUOTE_PREVIEW;
                this.showPdfModal   = true;
            }

        } else if (error) {
            console.error('Error fetching Quote record:', error);
            // Fallback: open PDF directly
            this.selectedFormat = FORMAT_QUOTE_PREVIEW;
            this.showPdfModal   = true;
        }
    }

    // ── Format label / desc / icon getters ───────────────────────────────────
    get selectedFormatLabel() {
        return FORMAT_META[this.selectedFormat]?.label || 'Quote Preview';
    }
    get selectedFormatDesc() {
        return FORMAT_META[this.selectedFormat]?.desc || '';
    }
    get selectedFormatIcon() {
        return FORMAT_META[this.selectedFormat]?.icon || 'doctype:pdf';
    }
    get isQuotePreviewSelected() { return this.selectedFormat === FORMAT_QUOTE_PREVIEW; }
    get isQuoteSummarySelected() { return this.selectedFormat === FORMAT_QUOTE_SUMMARY; }
    get isFormatConfirmDisabled() { return !this.selectedFormat; }

    // ── Dropdown trigger CSS ──────────────────────────────────────────────────
    get dropdownTriggerClass() {
        return this.isDropdownOpen
            ? 'picker-dropdown-trigger picker-dropdown-trigger_open'
            : 'picker-dropdown-trigger';
    }

    // ── Dropdown option CSS (highlight active) ────────────────────────────────
    get previewOptionClass() {
        return this.isQuotePreviewSelected
            ? 'picker-option picker-option_active'
            : 'picker-option';
    }
    get summaryOptionClass() {
        return this.isQuoteSummarySelected
            ? 'picker-option picker-option_active'
            : 'picker-option';
    }

    // ── Dropdown handlers ─────────────────────────────────────────────────────
    toggleDropdown(e) {
        e.stopPropagation();
        this.isDropdownOpen = !this.isDropdownOpen;
    }

    handleDropdownSelect(e) {
        e.stopPropagation();
        const value = e.currentTarget.dataset.value;
        if (value) {
            this.selectedFormat = value;
        }
        this.isDropdownOpen = false;
    }

    // Close dropdown if user clicks outside the menu area
    handleDropdownBackdropClick(e) {
        e.stopPropagation();
    }

    // ── Format picker confirm / back ──────────────────────────────────────────
    handleFormatConfirm() {
        this.isDropdownOpen   = false;
        this.showFormatPicker = false;
        this.showPdfModal     = true;
    }       

    handleBackToFormatPicker() {
        this.showPdfModal     = false;
        this.showFormatPicker = true;
    }

    // ── PDF URL ───────────────────────────────────────────────────────────────
    get pdfUrl() {
        return `/apex/${this.selectedFormat}?id=${this.recordId}`;
    }

    // ── Cancel / close ────────────────────────────────────────────────────────
    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ── Save Only ─────────────────────────────────────────────────────────────
    async handleSaveOnly() {
        this.isLoading = true;
        try {
            await generateQuoteDocument({
                quoteId    : this.recordId,
                pageFormat : this.selectedFormat
            });
            this.showToast('Success', 'Quote PDF saved successfully', 'success');
            this.dispatchEvent(new CloseActionScreenEvent());
            setTimeout(() => { window.location.reload(); }, 700);
        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
            this.isLoading = false;
        }
    }

    // ── Save & Send ───────────────────────────────────────────────────────────
    async handleSaveAndSend() {
        this.isLoadingforSaveandsend = true;
        try {
            await generateQuoteDocument({
                quoteId    : this.recordId,
                pageFormat : this.selectedFormat
            });

            const fileData = await getLatestQuoteFile({ quoteId: this.recordId });
            if (fileData) {
                this.attachments = [
                    ...(this.attachments || []),
                    {
                        title       : fileData.name + '_' + Date.now(),
                        content     : fileData.data,
                        contentType : 'application/pdf'
                    }
                ];
            }

            const templateData = await getQuoteEmailTemplate({ quoteId: this.recordId });
            this.subject = templateData?.subject || '';
            this.body    = templateData?.body || '';

            this.showToast('Success', 'Quote PDF saved successfully', 'success');
            this.showPdfModal      = false;
            this.showEmailComposer = true;

        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
        } finally {
            this.isLoadingforSaveandsend = false;
        }
    }

    // ── Email Composer fields ─────────────────────────────────────────────────
    @track fromOptions = [];
    @track fromEmail;

    @track toInput  = '';
    @track ccInput  = '';
    @track bccInput = '';
    @track toList   = [];
    @track ccList   = [];
    @track bccList  = [];

    @track toSearchResults  = [];
    @track ccSearchResults  = [];
    @track bccSearchResults = [];

    searchTimeout;
    @track subject = '';
    @track body    = '';

    connectedCallback() {
        getFromAddresses()
            .then(result => {
                this.fromOptions = result.map(e => ({ label: e, value: e }));
                this.fromEmail   = this.fromOptions[0]?.value;
            })
            .catch(() => {
                this.showToast('Error', 'Failed to load From addresses', 'error');
            });
    }

    handleFromChange(e)    { this.fromEmail = e.detail.value; }
    handleSubjectChange(e) { this.subject   = e.detail.value; }
    handleBodyChange(e)    { this.body      = e.detail.value; }

    // ── Email search / pill handling ──────────────────────────────────────────
    async handleTyping(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        this[`${field}Input`] = value;

        if (!value) { this[`${field}SearchResults`] = []; return; }

        clearTimeout(this.searchTimeout);
        this.searchTimeout = setTimeout(async () => {
            try {
                this[`${field}SearchResults`] = await searchEmails({ keyword: value });
            } catch {
                this[`${field}SearchResults`] = [];
            }
        }, 300);
    }

    handleKeyPress(event) {
        const field = event.target.dataset.field;
        let value   = event.target.value;
        if (event.key === 'Enter' || event.key === ',' || event.key === ';') {
            event.preventDefault();
            value = value.trim().replace(/[;,]$/, '');
            if (value && this.validateEmail(value)) {
                const list = this[`${field}List`];
                if (!list.includes(value)) this[`${field}List`] = [...list, value];
                this[`${field}Input`]         = '';
                this[`${field}SearchResults`] = [];
            } else if (value) {
                this.showToast('Error', `Enter valid email address in '${field}' field`, 'error');
            }
        }
    }

    validateEmail(email) {
        return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
    }

    handleSelect(e) {
        const field = e.currentTarget.dataset.field;
        const email = e.currentTarget.dataset.email;
        const list  = this[`${field}List`];
        if (!list.includes(email)) this[`${field}List`] = [...list, email];
        this[`${field}Input`]         = '';
        this[`${field}SearchResults`] = [];
    }

    removeEmail(e) {
        const field = e.currentTarget.dataset.field;
        const email = e.currentTarget.dataset.email;
        this[`${field}List`] = this[`${field}List`].filter(a => a !== email);
    }

    // ── Send email ────────────────────────────────────────────────────────────
    @track isSending = false;

    get sendButtonLabel() { return this.isSending ? 'Sending...' : 'Send Email'; }

    handleSend() {
        if (this.toList.length === 0) {
            this.showToast('Error', 'Please enter at least one To address.', 'error');
            return;
        }
        this.isSending = true;
        sendQuoteEmail({
            quoteId         : this.recordId,
            fromAddress     : this.fromEmail,
            toAddresses     : this.toList.join(','),
            ccAddresses     : this.ccList.join(','),
            bccAddresses    : this.bccList.join(','),
            subject         : this.subject,
            bodyHtml        : this.body,
            attachmentsJson : this.attachments
        })
        .then(() => {
            this.showToast('Success', 'Email sent successfully with Quote PDF!', 'success');
            this.toList = []; this.ccList = []; this.bccList = [];
            this.subject = ''; this.body = ''; this.attachments = [];
            this.dispatchEvent(new CloseActionScreenEvent());
            setTimeout(() => { window.location.reload(); }, 800);
        })
        .catch(error => {
            this.showToast('Error', error.body?.message || error.message, 'error');
            this.isSending = false;
        });
    }

    // ── File attachments ──────────────────────────────────────────────────────
    async handleLocalFileUpload(event) {
        const files = event.target.files;
        if (!files || files.length === 0) return;
        const attachmentsCopy = [...(this.attachments || [])];
        for (let file of files) {
            const base64 = await this.getBase64(file);
            attachmentsCopy.push({ title: file.name, content: base64, contentType: file.type });
        }
        this.attachments = attachmentsCopy;
    }

    getBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload  = () => resolve(reader.result.split(',')[1]);
            reader.onerror = error => reject(error);
            reader.readAsDataURL(file);
        });
    }

    triggerFileInput() {
        this.template.querySelector('.hidden-file-input').click();
    }

    handleRemoveAttachment(event) {
        const fileName   = event.target.name;
        this.attachments = this.attachments.filter(file => file.title !== fileName);
    }

    // ── Toast utility ─────────────────────────────────────────────────────────
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}