import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue, getRecordNotifyChange } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import deleteInvoiceForJob from '@salesforce/apex/JobInvoiceController.deleteInvoiceForJob';

import JOB_INVOICE_REQUIRED from '@salesforce/schema/fax__Job__c.Invoice_Required__c';
import JOB_STATUS from '@salesforce/schema/fax__Job__c.fax__Status__c';

const JOB_FIELDS = [JOB_INVOICE_REQUIRED, JOB_STATUS];
const COMPLETED_STATUSES = new Set(['Completed', 'Finalized']);
const CONFIRM_MESSAGE =
    "Are you sure this job doesn't need an invoice? If you continue, the related invoice will be deleted.";

export default class InvoiceDeletionAlertFromJob extends LightningElement {
    @api recordId;

    previousInvoiceRequired;
    hasInitializedInvoiceRequired = false;
    isConfirmDialogOpen = false;

    @wire(getRecord, { recordId: '$recordId', fields: JOB_FIELDS })
    wiredJob({ data, error }) {
        if (error) {
            console.error('invoiceDeletionAlertFromJob record wire error', JSON.stringify(error));
            return;
        }

        if (!data) {
            return;
        }

        const invoiceRequired = getFieldValue(data, JOB_INVOICE_REQUIRED);
        const status = getFieldValue(data, JOB_STATUS);

        if (!this.hasInitializedInvoiceRequired) {
            this.previousInvoiceRequired = invoiceRequired;
            this.hasInitializedInvoiceRequired = true;
            return;
        }

        const invoiceRequiredChangedToFalse =
            this.previousInvoiceRequired === true && invoiceRequired === false;
        this.previousInvoiceRequired = invoiceRequired;

        if (
            invoiceRequiredChangedToFalse &&
            COMPLETED_STATUSES.has(status) &&
            !this.isConfirmDialogOpen
        ) {
            this.promptInvoiceDeletion();
        }
    }

    async promptInvoiceDeletion() {
        this.isConfirmDialogOpen = true;

        try {
            const confirmed = await LightningConfirm.open({
                message: CONFIRM_MESSAGE,
                label: 'Confirm Invoice Removal',
                theme: 'warning'
            });

            if (confirmed) {
                await this.deleteRelatedInvoice();
            }
        } finally {
            this.isConfirmDialogOpen = false;
        }
    }

    async deleteRelatedInvoice() {
        try {
            await deleteInvoiceForJob({ jobId: this.recordId });
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Related invoice was deleted.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: this.getErrorMessage(error),
                    variant: 'error'
                })
            );
        }
    }

    getErrorMessage(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'An unexpected error occurred while deleting the invoice.';
    }
}