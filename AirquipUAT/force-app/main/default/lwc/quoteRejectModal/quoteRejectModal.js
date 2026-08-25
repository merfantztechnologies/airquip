import { LightningElement, api, wire,track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import {
    getRecord,
    getFieldValue,
    updateRecord,
    getRecordNotifyChange
} from 'lightning/uiRecordApi';

import QUOTE_OPP_ID from '@salesforce/schema/Quote.OpportunityId';
import QUOTE_OPP_NAME from '@salesforce/schema/Quote.Opportunity.Name';

const QUOTE_FIELDS = [QUOTE_OPP_ID, QUOTE_OPP_NAME];

export default class QuoteRejectModal extends LightningElement {

    @api recordId;

    opportunityName;
    opportunityId;
    isLoading = true;
    isSaving = false;
    @track selectedStage = 'On Hold / Future Follow-Up';

    @wire(getRecord, {
        recordId: '$recordId',
        fields: QUOTE_FIELDS
    })
    wiredQuote({ data, error }) {

        if (error) {
            this.showError(error);
            return;
        }

        if (!data) {
            return;
        }

        this.opportunityId = getFieldValue(data, QUOTE_OPP_ID);
        this.opportunityName = getFieldValue(data, QUOTE_OPP_NAME);

        if (!this.opportunityId) {
            this.rejectQuoteOnly();
            return;
        }

        this.isLoading = false;
    }

    get hasOpportunity() {
        return Boolean(this.opportunityId);
    }
    handleStageChange(event) {
        this.selectedStage = event.detail.value;
    }

    get showLostReason() {
        return this.selectedStage === 'Closed Lost';
    }
    

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    async handleSave() {

        if (this.isSaving) {
            return;
        }

        this.isSaving = true;

        try {

            const opportunityFields = {
                Id: this.opportunityId
            };

            const inputFields = this.template.querySelectorAll('lightning-input-field');

            inputFields.forEach(field => {
                opportunityFields[field.fieldName] = field.value;
            });

            // Update Opportunity
            await updateRecord({ fields: opportunityFields });

            // Update Quote Status to Rejected
            await updateRecord({
                fields: {
                    Id: this.recordId,
                    Status: 'Rejected'
                }
            });

            getRecordNotifyChange([
                { recordId: this.recordId },
                { recordId: this.opportunityId }
            ]);

            this.showToast(
                'Success',
                'Quote has been rejected successfully.',
                'success'
            );

            this.dispatchEvent(new CloseActionScreenEvent());

        } catch (error) {

            this.showError(error);

        } finally {

            this.isSaving = false;
            this.isLoading = false;
        }
    }

    async rejectQuoteOnly() {

        try {

            await updateRecord({
                fields: {
                    Id: this.recordId,
                    Status: 'Rejected'
                }
            });

            getRecordNotifyChange([{ recordId: this.recordId }]);

            this.showToast(
                'Success',
                'Quote has been rejected successfully.',
                'success'
            );

            this.dispatchEvent(new CloseActionScreenEvent());

        } catch (error) {
            this.showError(error);
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    showError(error) {

        console.error('FULL ERROR => ', JSON.stringify(error));

        let message = 'Unknown error';

        // UI API field validation errors
        if (error?.body?.output?.errors?.length > 0) {
            message = error.body.output.errors.map(err => err.message).join(', ');

        // Field level validation rule errors
        } else if (error?.body?.output?.fieldErrors) {
            const fieldErrors = error.body.output.fieldErrors;
            const errorMessages = [];
            Object.keys(fieldErrors).forEach(field => {
                fieldErrors[field].forEach(err => errorMessages.push(err.message));
            });
            message = errorMessages.join(', ');

        // Apex / DML errors
        } else if (error?.body?.message) {
            message = error.body.message;

        // JS errors
        } else if (error?.message) {
            message = error.message;
        }

        this.showToast('Error', message, 'error');
    }
}