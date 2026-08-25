import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import FORM_FACTOR from '@salesforce/client/formFactor';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import getMyAssignmentContext from '@salesforce/apex/AssignmentTriggerHandler.getMyAssignmentContext';
import updateMyAssignmentStatus from '@salesforce/apex/AssignmentTriggerHandler.updateMyAssignmentStatus';
import updateMyAssignment from '@salesforce/apex/AssignmentTriggerHandler.updateMyAssignment';

export default class JobAssignment extends LightningElement {
    @api recordId;

    assignment;
    allAssignments = [];
    statusOptions = [];
    assignmentCount = 0;
    isVisible = false;
    canEditOwnAssignment = false;
    isLoading = true;
    isSaving = false;
    isEditMode = false;
    errorMessage;

    editPlannedStart;
    editPlannedEnd;
    editAllDay = false;
    editRejectionReason;

    locationEnabled = false;
    latitude;
    longitude;
    locationMessage;
    showLocationPopup = false;

    wiredContextResult;
    _locationListenerAttached = false;

    @wire(getMyAssignmentContext, { jobId: '$recordId' })
    wiredContext(result) {
        this.wiredContextResult = result;
        const { data, error } = result;

        if (data) {
            this.isVisible = data.isVisible;
            this.assignmentCount = data.assignmentCount;
            this.canEditOwnAssignment = data.canEditOwnAssignment;
            this.assignment = data.assignment ? { ...data.assignment } : null;
            this.allAssignments = this.decorateAssignments(data.allAssignments || []);
            this.statusOptions = data.statusOptions || [];
            this.resetEditFields();
            this.errorMessage = undefined;
            this.isLoading = false;
        } else if (error) {
            this.isVisible = false;
            this.errorMessage = this.reduceError(error);
            this.isLoading = false;
        }
    }

    connectedCallback() {
        this.captureLocation();
        this.attachLocationRetryListener();
    }

    disconnectedCallback() {
        if (this._locationListenerAttached) {
            document.removeEventListener('visibilitychange', this.handleVisibilityChange);
            this._locationListenerAttached = false;
        }
    }

    attachLocationRetryListener() {
        if (this._locationListenerAttached) {
            return;
        }
        this.handleVisibilityChange = this.handleVisibilityChange.bind(this);
        document.addEventListener('visibilitychange', this.handleVisibilityChange);
        this._locationListenerAttached = true;
    }

    handleVisibilityChange() {
        if (document.visibilityState === 'visible' && !this.locationEnabled) {
            this.captureLocation();
        }
    }

    get showComponent() {
        return this.isVisible && this.assignment;
    }

    get isCompactLayout() {
        return FORM_FACTOR === 'Small' || FORM_FACTOR === 'Medium';
    }

    get cardClass() {
        return `assignment-card slds-card${this.isCompactLayout ? ' assignment-card--compact' : ''}`;
    }

    get headerClass() {
        return `card-header slds-grid${this.isCompactLayout ? ' card-header--stacked' : ''}`;
    }

    get actionRowClass() {
        return `action-row${this.isCompactLayout ? ' action-row--stacked' : ''}`;
    }

    get isSaveEditDisabled() {
        return this.isSaving;
    }

    handleEditPlannedStartChange(event) {
        this.editPlannedStart = event.detail.value;
    }

    handleEditPlannedEndChange(event) {
        this.editPlannedEnd = event.detail.value;
    }

    handleEditAllDayChange(event) {
        this.editAllDay = event.target.checked;
    }

    handleEditRejectionReasonChange(event) {
        this.editRejectionReason = event.detail.value;
    }

    handleEnterEditMode() {
        this.errorMessage = undefined;
        this.resetEditFields();
        this.isEditMode = true;
    }

    handleCancelEdit() {
        this.errorMessage = undefined;
        this.resetEditFields();
        this.isEditMode = false;
    }

    handleDismissError() {
        this.errorMessage = undefined;
    }

    handleCloseLocationPopup() {
        this.showLocationPopup = false;
    }

    async handleRowStatusChange(event) {
        const combobox = event.currentTarget;
        const assignmentId = combobox.dataset.assignmentId;
        const newStatus = event.detail.value;
        const currentStatus = combobox.dataset.currentStatus;

        if (!assignmentId || !newStatus || newStatus === currentStatus) {
            return;
        }

        if (!this.locationEnabled) {
            await this.captureLocation(true);
        }

        if (!this.locationEnabled) {
            this.showLocationPopup = true;
            combobox.value = currentStatus;
            return;
        }

        this.isSaving = true;
        this.errorMessage = undefined;

        try {
            await updateMyAssignmentStatus({
                assignmentId,
                newStatus,
                latitude: this.latitude,
                longitude: this.longitude
            });
            this.showToast('Success', 'Assignment status updated.', 'success');
            await this.refreshData();
        } catch (error) {
            const message = this.reduceError(error);
            this.errorMessage = message;
            combobox.value = currentStatus;
            this.showToast('Unable to update status', message, 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async handleSaveEdit() {
        if (!this.assignment?.id) {
            return;
        }

        this.isSaving = true;
        this.errorMessage = undefined;

        try {
            await updateMyAssignment({
                assignmentId: this.assignment.id,
                plannedStart: this.editPlannedStart || null,
                plannedEnd: this.editPlannedEnd || null,
                allDay: this.editAllDay,
                rejectionReason: this.editRejectionReason
            });
            this.isEditMode = false;
            this.showToast('Success', 'Assignment updated.', 'success');
            await this.refreshData();
        } catch (error) {
            const message = this.reduceError(error);
            this.errorMessage = message;
            this.showToast('Unable to save assignment', message, 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async refreshData() {
        await refreshApex(this.wiredContextResult);
        if (this.assignment?.id) {
            getRecordNotifyChange([{ recordId: this.assignment.id }]);
        }
        getRecordNotifyChange([{ recordId: this.recordId }]);
    }

    resetEditFields() {
        this.editPlannedStart = this.toInputDateTime(this.assignment?.plannedStart);
        this.editPlannedEnd = this.toInputDateTime(this.assignment?.plannedEnd);
        this.editAllDay = Boolean(this.assignment?.allDay);
        this.editRejectionReason = this.assignment?.rejectionReason || '';
    }

    captureLocation(requireFresh = false) {
        return new Promise((resolve) => {
            if (!navigator.geolocation) {
                this.locationEnabled = false;
                this.locationMessage =
                    'Enable location on your device to update assignment status.';
                resolve();
                return;
            }

            if (!requireFresh && this.locationEnabled) {
                resolve();
                return;
            }

            navigator.geolocation.getCurrentPosition(
                (position) => {
                    this.latitude = String(position.coords.latitude);
                    this.longitude = String(position.coords.longitude);
                    this.locationEnabled = true;
                    this.locationMessage = undefined;
                    this.showLocationPopup = false;
                    resolve();
                },
                () => {
                    this.locationEnabled = false;
                    this.locationMessage =
                        'Location access is required to update assignment status.';
                    resolve();
                },
                {
                    enableHighAccuracy: true,
                    timeout: 10000,
                    maximumAge: requireFresh ? 0 : 60000
                }
            );
        });
    }

    formatDateTime(value) {
        if (!value) {
            return '—';
        }
        return new Intl.DateTimeFormat(undefined, {
            month: 'short',
            day: '2-digit',
            hour: 'numeric',
            minute: '2-digit'
        }).format(new Date(value));
    }

    toInputDateTime(value) {
        if (!value) {
            return null;
        }
        const date = new Date(value);
        const offset = date.getTimezoneOffset();
        const local = new Date(date.getTime() - offset * 60000);
        return local.toISOString().slice(0, 16);
    }

    decorateAssignments(assignments) {
        return assignments.map((row) => ({
            ...row,
            scheduledStartDisplay: this.formatDateTime(row.scheduledStart),
            scheduledEndDisplay: this.formatDateTime(row.scheduledEnd),
            statusBadgeClass: this.getStatusBadgeClass(row.status),
            rowClass: row.isOwnAssignment ? 'assignment-row assignment-row--own' : 'assignment-row'
        }));
    }

    getStatusBadgeClass(status) {
        const normalized = (status || '').toLowerCase().replace(/\s+/g, '-');
        return `status-badge status-badge--${normalized || 'default'}`;
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

    reduceError(error) {
        if (!error) {
            return 'An unexpected error occurred. Please try again.';
        }

        if (Array.isArray(error.body)) {
            return error.body.map((entry) => entry.message).filter(Boolean).join(' ');
        }

        if (Array.isArray(error.body?.output?.errors)) {
            return error.body.output.errors.map((entry) => entry.message).filter(Boolean).join(' ');
        }

        if (Array.isArray(error.body?.pageErrors) && error.body.pageErrors.length) {
            return error.body.pageErrors.map((entry) => entry.message).filter(Boolean).join(' ');
        }

        if (error.body?.fieldErrors) {
            const fieldMessages = [];
            Object.keys(error.body.fieldErrors).forEach((fieldName) => {
                error.body.fieldErrors[fieldName].forEach((entry) => {
                    if (entry?.message) {
                        fieldMessages.push(entry.message);
                    }
                });
            });
            if (fieldMessages.length) {
                return fieldMessages.join(' ');
            }
        }

        const message = error.body?.message || error.message;
        return message ? this.cleanApexMessage(message) : 'An unexpected error occurred. Please try again.';
    }

    cleanApexMessage(message) {
        if (!message) {
            return message;
        }

        let cleaned = message.trim();

        const validationMatch = cleaned.match(/FIELD_CUSTOM_VALIDATION_EXCEPTION,\s*(.+?)(?::\s*\[|$)/i);
        if (validationMatch?.[1]) {
            cleaned = validationMatch[1].trim();
        }

        const firstErrorMatch = cleaned.match(/first error:\s*(.+)$/i);
        if (firstErrorMatch?.[1]) {
            cleaned = firstErrorMatch[1].trim();
        }

        cleaned = cleaned.replace(/^Update failed\.\s*/i, '');
        cleaned = cleaned.replace(/^Insert failed\.\s*/i, '');
        cleaned = cleaned.replace(/:\s*\[[^\]]+\]\s*$/i, '');

        return cleaned.trim();
    }
}