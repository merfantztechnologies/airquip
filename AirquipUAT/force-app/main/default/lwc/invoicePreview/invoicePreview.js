import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

import generateDocument from '@salesforce/apex/DocumentService.generateDocument';
import getFromAddresses from '@salesforce/apex/DocumentEmailService.getFromAddresses';
import getDefaultCcEmails from '@salesforce/apex/DocumentEmailService.getDefaultCcEmails';

import searchContactEmails from '@salesforce/apex/DocumentEmailService.searchContactEmails';
import searchInternalUsers from '@salesforce/apex/DocumentEmailService.searchInternalUsers';
// Add this import at the top with the other imports
import getEmailTemplateAndSignature from '@salesforce/apex/DocumentEmailService.getEmailTemplateAndSignature';

import sendEmail from '@salesforce/apex/DocumentEmailService.sendEmail';
import getLatestFile from '@salesforce/apex/DocumentService.getLatestFile';

import JOB_FIELD from '@salesforce/schema/fax__Invoice__c.fax__Job__c';
import JOB_EMAIL from '@salesforce/schema/fax__Job__c.Contact_Email__c';
import INVOICE_OBJECT from '@salesforce/schema/fax__Invoice__c';

export default class InvoicePreview extends NavigationMixin(LightningElement) {

    @api recordId;

    @track jobId;
    @track attachments = [];

    @track isLoading = false;
    @track isLoadingforSaveandsend = false;
    @track isSending = false;

    @track showPdfModal = true;
    @track showEmailComposer = false;

    @track fromOptions = [];
    @track fromEmail;

    @track toInput = '';
    @track ccInput = '';
    @track bccInput = '';

    @track toList = [];
    @track ccList = [];
    @track bccList = [];

    @track toSearchResults = [];
    @track ccSearchResults = [];
    @track bccSearchResults = [];

    @track subject = 'Your Invoice is Ready!';
    @track body = '';

    @track pageRecordId;


    /*
    =============================================
    PAGE REFERENCE
    =============================================
    */
    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {

        const rid =
            pageRef?.state?.recordId ||
            pageRef?.state?.c__recordId ||
            pageRef?.attributes?.recordId;

        if (rid) {
            this.pageRecordId = rid;
        }
    }

    get resolvedRecordId() {
        return this.recordId || this.pageRecordId;
    }


    /*
    =============================================
    PDF URL
    =============================================
    */
    get pdfUrl() {

        const id = this.resolvedRecordId;

        if (!id) {
            return '';
        }

        try {

            const origin = window.location.origin;

            return `${origin}/apex/InvoicePreview?id=${encodeURIComponent(id)}&isdtp=p1`;

        } catch (e) {

            return `/apex/InvoicePreview?id=${encodeURIComponent(id)}&isdtp=p1`;
        }
    }

    get hasPdfUrl() {
        return !!this.pdfUrl;
    }


    /*
    =============================================
    LOAD INVOICE
    =============================================
    */
    @wire(getRecord, {
        recordId: '$recordId',
        fields: [JOB_FIELD]
    })
    wiredInvoice({ data, error }) {

        if (data) {

            this.jobId = getFieldValue(data, JOB_FIELD);

        } else if (error && this.recordId) {

            this.showError('Failed loading Invoice', error);
        }
    }


    /*
    =============================================
    LOAD JOB EMAIL
    =============================================
    */
    @wire(getRecord, {
        recordId: '$jobId',
        fields: [JOB_EMAIL]
    })
    wiredJob({ data, error }) {

        if (data) {

            const email = getFieldValue(data, JOB_EMAIL);

            if (email) {
                this.toList = [email];
            }

        } else if (error) {

            this.showError('Failed loading Job email', error);
        }
    }


    /*
    =============================================
    LIFECYCLE
    =============================================
    */
    connectedCallback() {

        this.loadFromEmails();
        this.loadDefaultCc();
        this.loadEmailTemplateAndSignature(); // ← add this line
    }

    renderedCallback() {

        const host = this.template?.host;

        if (host) {
            host.classList.toggle(
                'composer-open',
                this.showEmailComposer === true
            );
        }
    }


    /*
    =============================================
    LOAD FROM EMAILS
    =============================================
    */
    async loadFromEmails() {

        try {

            const res = await getFromAddresses();

            if (res?.length) {

                this.fromOptions = res.map(e => ({
                    label: e,
                    value: e
                }));

                this.fromEmail = res[0];
            }

        } catch (e) {

            this.showError(
                'Failed to load From addresses',
                e
            );
        }
    }


    /*
    =============================================
    DEFAULT CC EMAILS
    =============================================
    */
    async loadDefaultCc() {

        try {

            const result = await getDefaultCcEmails();

            if (result) {
                this.bccList = result;
            }

        } catch (e) {

            this.showError(
                'Failed loading default CC emails',
                e
            );
        }
    }


    /*
    =============================================
    FROM / SUBJECT / BODY
    =============================================
    */
    handleFromChange(event) {
        this.fromEmail = event.detail.value;
    }

    handleSubjectChange(event) {
        this.subject = event.target.value;
    }

    handleBodyChange(event) {
        this.body = event.detail.value;
    }


    /*
    =============================================
    TO / CC / BCC SEARCH
    =============================================
    */
    handleTyping(event) {

        const field = event.target.dataset.field;
        const value = event.target.value;

        if (field === 'to') {
            this.toInput = value;
        } else if (field === 'cc') {
            this.ccInput = value;
        } else if (field === 'bcc') {
            this.bccInput = value;
        }

        if (value.length < 2) {

            this.clearSearchResults(field);
            return;
        }

        this.doSearch(field, value);
    }


    /*
    =============================================
    SEARCH LOGIC
    TO => CONTACTS
    CC/BCC => INTERNAL USERS
    =============================================
    */
    async doSearch(field, query) {

        try {

            let results = [];

            if (field === 'to') {
            console.log('searchContactEmails called with:', {
                keyword: query,
                invoiceId: this.recordId  // ← check if this is null
            });

            results = await searchContactEmails({
                keyword: query,
                invoiceId: this.resolvedRecordId  // ← use resolvedRecordId instead of recordId
            });
        } else {
            results = await searchInternalUsers({ keyword: query });
        }

            if (field === 'to') {

                this.toSearchResults = results || [];

            } else if (field === 'cc') {

                this.ccSearchResults = results || [];

            } else if (field === 'bcc') {

                this.bccSearchResults = results || [];
            }

        } catch (e) {

            this.showError('Search failed', e);
        }
    }


    /*
    =============================================
    SELECT EMAIL
    =============================================
    */
    handleSelect(event) {

        const email =
            event.currentTarget.dataset.email;

        const field =
            event.currentTarget.dataset.field;

        if (!email) {
            return;
        }

        if (
            field === 'to' &&
            !this.toList.includes(email)
        ) {

            this.toList = [...this.toList, email];
            this.toInput = '';
            this.toSearchResults = [];

        } else if (
            field === 'cc' &&
            !this.ccList.includes(email)
        ) {

            this.ccList = [...this.ccList, email];
            this.ccInput = '';
            this.ccSearchResults = [];

        } else if (
            field === 'bcc' &&
            !this.bccList.includes(email)
        ) {

            this.bccList = [...this.bccList, email];
            this.bccInput = '';
            this.bccSearchResults = [];
        }
    }


    /*
    =============================================
    ENTER / COMMA
    =============================================
    */
    handleKeyPress(event) {

        if (
            event.key === 'Enter' ||
            event.key === ','
        ) {

            event.preventDefault();

            const field =
                event.target.dataset.field;

            const value =
                event.target.value
                    .replace(',', '')
                    .trim();

            if (value) {
                this.addEmailToList(field, value);
            }
        }
    }


    /*
    =============================================
    ADD EMAIL
    =============================================
    */
    addEmailToList(field, email) {

        if (
            field === 'to' &&
            !this.toList.includes(email)
        ) {

            this.toList = [...this.toList, email];
            this.toInput = '';
            this.toSearchResults = [];

        } else if (
            field === 'cc' &&
            !this.ccList.includes(email)
        ) {

            this.ccList = [...this.ccList, email];
            this.ccInput = '';
            this.ccSearchResults = [];

        } else if (
            field === 'bcc' &&
            !this.bccList.includes(email)
        ) {

            this.bccList = [...this.bccList, email];
            this.bccInput = '';
            this.bccSearchResults = [];
        }
    }


    /*
    =============================================
    REMOVE EMAIL
    =============================================
    */
    removeEmail(event) {

        const email =
            event.currentTarget.dataset.email;

        const field =
            event.currentTarget.dataset.field;

        if (field === 'to') {

            this.toList =
                this.toList.filter(e => e !== email);

        } else if (field === 'cc') {

            this.ccList =
                this.ccList.filter(e => e !== email);

        } else if (field === 'bcc') {

            this.bccList =
                this.bccList.filter(e => e !== email);
        }
    }


    /*
    =============================================
    CLEAR SEARCH
    =============================================
    */
    clearSearchResults(field) {

        if (field === 'to') {

            this.toSearchResults = [];

        } else if (field === 'cc') {

            this.ccSearchResults = [];

        } else if (field === 'bcc') {

            this.bccSearchResults = [];
        }
    }


    /*
    =============================================
    FILE INPUT
    =============================================
    */
    triggerFileInput() {

        this.template
            .querySelector('.hidden-file-input')
            .click();
    }


    /*
    =============================================
    LOCAL FILE UPLOAD
    =============================================
    */
    handleLocalFileUpload(event) {

        const files =
            Array.from(event.target.files);

        files.forEach(file => {

            const reader = new FileReader();

            reader.onload = () => {

                const base64 =
                    reader.result.split(',')[1];

                this.attachments = [
                    ...this.attachments,
                    {
                        title: file.name,
                        content: base64,
                        contentType:
                            file.type ||
                            'application/octet-stream'
                    }
                ];
            };

            reader.readAsDataURL(file);
        });
    }


    /*
    =============================================
    REMOVE ATTACHMENT
    =============================================
    */
    handleRemoveAttachment(event) {

        const name = event.detail.item.name;

        this.attachments =
            this.attachments.filter(
                a => a.title !== name
            );
    }


    /*
    =============================================
    CANCEL
    =============================================
    */
    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
        this.dispatchEvent(
            new CustomEvent('lightning__actionsclosescreen', {
                bubbles: true,
                composed: true
            })
        );

        const recordId = this.resolvedRecordId;
        if (!recordId) {
            return;
        }

        try {
            this[NavigationMixin.Navigate](
                {
                    type: 'standard__recordPage',
                    attributes: {
                        recordId,
                        objectApiName: INVOICE_OBJECT.objectApiName,
                        actionName: 'view'
                    }
                },
                true
            );
        } catch (e) {
            console.warn('invoicePreview: cancel navigation failed', e);
        }
    }

    handleBackToPreview() {
        this.showEmailComposer = false;
        this.showPdfModal = true;
    }


    /*
    =============================================
    SAVE ONLY
    =============================================
    */
    async handleSaveOnly() {

        const currentRecordId =
            this.resolvedRecordId;

        if (!currentRecordId) {

            this.showToast(
                'Error',
                'Invoice record not found',
                'error'
            );

            return;
        }

        this.isLoading = true;

        try {

            await generateDocument({
                recordId: currentRecordId,
                vfPageName: 'InvoicePreview'
            });

            this.showToast(
                'Success',
                'Invoice PDF saved successfully',
                'success'
            );

            this.dispatchEvent(
                new CloseActionScreenEvent()
            );

        } catch (e) {

            this.showError(
                'Failed to generate Invoice PDF',
                e
            );

        } finally {

            this.isLoading = false;
        }
    }

    /*
=============================================
SAVE & SEND
=============================================
*/
async handleSaveAndSend() {

    const currentRecordId =
        this.resolvedRecordId;

    if (!currentRecordId) {

        this.showToast(
            'Error',
            'Invoice record not found',
            'error'
        );

        return;
    }

    this.isLoadingforSaveandsend = true;

    try {

        // Generate PDF
        await generateDocument({
            recordId: currentRecordId,
            vfPageName: 'InvoicePreview'
        });

        // Get Latest File
        const fileData =
            await getLatestFile({
                recordId: currentRecordId
            });

        if (!fileData) {
            throw new Error(
                'Invoice PDF not found'
            );
        }

        // Attach generated PDF
        this.attachments = [{
            title: fileData.name,
            content: fileData.data,
            contentType: 'application/pdf'
        }];

        // Open Email Composer
        this.showPdfModal = false;
        this.showEmailComposer = true;

    } catch (e) {

        this.showError(
            'Failed during Save & Send',
            e
        );

    } finally {

        this.isLoadingforSaveandsend = false;
    }
}


/*
=============================================
SEND EMAIL
=============================================
*/
async handleSend() {

    const currentRecordId =
        this.resolvedRecordId;

    if (!currentRecordId) {

        this.showToast(
            'Error',
            'Invoice record not found',
            'error'
        );

        return;
    }

    // Validate TO emails
    if (this.toList.length === 0) {

        this.showToast(
            'Error',
            'Please add at least one recipient',
            'error'
        );

        return;
    }

    this.isSending = true;

    try {

        await sendEmail({

            recordId: currentRecordId,

            fromAddress: this.fromEmail,

            toAddresses:
                this.toList.join(','),

            ccAddresses:
                this.ccList.join(','),

            bccAddresses:
                this.bccList.join(','),

            subject: this.subject,

            bodyHtml: this.body,

            attachmentsJson:
                this.attachments
        });

        this.showToast(
            'Success',
            'Invoice Email Sent',
            'success'
        );

        this.dispatchEvent(
            new CloseActionScreenEvent()
        );

        setTimeout(() => {
            location.reload();
        }, 800);

    } catch (e) {

        this.showError(
            'Email sending failed',
            e
        );

    } finally {

        this.isSending = false;
    }
}


/*
=============================================
TOAST
=============================================
*/
showToast(title, message, variant) {

    this.dispatchEvent(
        new ShowToastEvent({
            title,
            message,
            variant
        })
    );
}

/*
=============================================
LOAD EMAIL TEMPLATE + SIGNATURE
=============================================
*/
async loadEmailTemplateAndSignature() {

    try {

        const currentRecordId = this.resolvedRecordId;

        if (!currentRecordId) {
            return;
        }

        const result = await getEmailTemplateAndSignature({
            recordId: currentRecordId
        });

        if (result) {

            const templateHtml = result.templateHtml || '';
            const signature    = result.signature    || '';

            // Combine: template body + line break + signature
            this.body =
                templateHtml +
                (signature
                    ? '<br/><br/>--<br/>' + signature
                    : '');
        }

    } catch (e) {

        this.showError(
            'Failed to load email template',
            e
        );
    }
}

/*
=============================================
ERROR
=============================================
*/
showError(context, error) {

    console.error(context, error);

    const msg =
        error?.body?.message ||
        error?.message ||
        'Unknown error';

    this.showToast(
        'Error',
        context + ': ' + msg,
        'error'
    );
}
}