import { LightningElement, api, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const CASE_FIELDS = ['Case.AccountId', 'Case.ContactId'];

export default class CreateJobFromCase extends LightningElement {
    @api recordId;
    accountId;
    contactId;
    isLoaded = false;

    @wire(getRecord, { recordId: '$recordId', fields: CASE_FIELDS })
    wiredCase({ error, data }) {
        if (data) {
            this.accountId = data.fields.AccountId.value;
            this.contactId = data.fields.ContactId.value;
            this.isLoaded = true;
        } else if (error) {
            console.error('Error fetching Case data: ', error);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error loading Case',
                    message: error.body.message,
                    variant: 'error'
                })
            );
        }
    }

    closeAction() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // New method to handle the manual form submission
    handleSubmit() {
        const form = this.template.querySelector('lightning-record-edit-form');
        if (form) {
            form.submit();
        }
    }

    handleSuccess(event) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Success',
                message: 'Job ' + event.detail.id + ' created successfully',
                variant: 'success'
            })
        );
        this.closeAction();
    }
}