import { api, LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEligibleJobs from '@salesforce/apex/ConsolidatedInvoiceController.getEligibleJobs';
import generateConsolidatedInvoice from '@salesforce/apex/ConsolidatedInvoiceController.generateConsolidatedInvoice';

const VALIDATION_NO_SELECTION = 'Please select at least one job.';

export default class ConsolidatedInvoice extends NavigationMixin(LightningElement) {
    jobs = [];
    selectedJobIds = [];
    errorMessage;
    isLoading = false;
    _recordId;

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.loadEligibleJobs();
        }
    }

    get hasJobs() {
        return this.jobs.length > 0;
    }

    get showNoJobsMessage() {
        return !this.hasJobs && !this.errorMessage;
    }

    get isGenerateDisabled() {
        return this.isLoading || this.selectedJobIds.length === 0;
    }

    get selectedJobCount() {
        return this.selectedJobIds.length;
    }

    get hasSelection() {
        return this.selectedJobCount > 0;
    }

    get allRowsSelected() {
        return this.hasJobs && this.selectedJobIds.length === this.jobs.length;
    }

    async loadEligibleJobs() {
        this.isLoading = true;
        this.errorMessage = undefined;
        this.selectedJobIds = [];

        try {
            const jobs = await getEligibleJobs({ accountId: this.recordId });
            this.jobs = this.decorateJobs(jobs);
        } catch (error) {
            this.jobs = [];
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleSelectAll(event) {
        if (event.target.checked) {
            this.selectedJobIds = this.jobs.map((job) => job.jobId);
        } else {
            this.selectedJobIds = [];
        }
        this.updateJobSelectionState();
    }

    handleJobSelection(event) {
        const jobId = event.target.dataset.jobId;
        if (!jobId) {
            return;
        }

        if (event.target.checked) {
            this.selectedJobIds = [...new Set([...this.selectedJobIds, jobId])];
        } else {
            this.selectedJobIds = this.selectedJobIds.filter((selectedJobId) => selectedJobId !== jobId);
        }

        this.updateJobSelectionState();
    }

    handleJobClick(event) {
        const jobId = event.currentTarget.dataset.jobId;
        if (!jobId) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: jobId,
                objectApiName: 'fax__Job__c',
                actionName: 'view'
            }
        });
    }

    async handleGenerateInvoice() {
        if (this.selectedJobIds.length === 0) {
            this.showToast('Validation', VALIDATION_NO_SELECTION, 'warning');
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result = await generateConsolidatedInvoice({
                accountId: this.recordId,
                jobIds: this.selectedJobIds
            });

            this.showToast(
                'Success',
                result.message || `${result.jobsAddedCount} job(s) were added successfully.`,
                'success'
            );

            if (result.invoiceId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: result.invoiceId,
                        objectApiName: 'fax__Invoice__c',
                        actionName: 'view'
                    }
                });
            }

            await this.loadEligibleJobs();
        } catch (error) {
            const message = this.reduceError(error);
            this.showToast('Unable to Generate Invoice', message, 'error');
            if (this.shouldReloadAfterError(message)) {
                await this.loadEligibleJobs();
            } else {
                this.errorMessage = message;
            }
        } finally {
            this.isLoading = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    decorateJobs(jobs) {
        return (jobs || []).map((job) => ({
            ...job,
            completionDateLabel: this.formatDate(job.completionDate),
            isSelected: this.selectedJobIds.includes(job.jobId),
            rowClass: this.selectedJobIds.includes(job.jobId)
                ? 'slds-hint-parent slds-is-selected'
                : 'slds-hint-parent',
            selectionLabel: `Select ${job.jobNumber || 'Job'}`
        }));
    }

    updateJobSelectionState() {
        this.jobs = this.decorateJobs(this.jobs);
    }

    formatDate(value) {
        if (!value) {
            return '';
        }

        return new Intl.DateTimeFormat(undefined, {
            year: 'numeric',
            month: 'short',
            day: '2-digit'
        }).format(new Date(value));
    }

    shouldReloadAfterError(message) {
        return (
            message?.includes('could not be found') ||
            message?.includes('no longer eligible') ||
            message?.includes('already on a consolidated invoice') ||
            message?.includes('Refresh the list')
        );
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((entry) => entry.message).join(', ');
        }

        return error?.body?.message || error?.message || 'An unexpected error occurred.';
    }
}