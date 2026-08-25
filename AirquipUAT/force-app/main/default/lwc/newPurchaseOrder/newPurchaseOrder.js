import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { getRecord } from 'lightning/uiRecordApi';
import { loadStyle } from 'lightning/platformResourceLoader';
import modal from '@salesforce/resourceUrl/modalPopup';
import USER_ID from '@salesforce/user/Id';

// Apex methods
import searchStandardProducts from '@salesforce/apex/NewPurchaseOrderController.searchStandardProducts';
import getPicklistValues from '@salesforce/apex/NewPurchaseOrderController.getPicklistValues';
import getClassOptions from '@salesforce/apex/NewPurchaseOrderController.getClassOptions';
import getCustomerAccounts from '@salesforce/apex/NewPurchaseOrderController.getCustomerAccounts';
import createPurchaseOrder from '@salesforce/apex/NewPurchaseOrderController.createPurchaseOrder';
import getRelatedRecordsForAccount from '@salesforce/apex/NewPurchaseOrderController.getRelatedRecordsForAccount';
import getOrderDetails from '@salesforce/apex/NewPurchaseOrderController.getOrderDetails';
import getContactsForAccount from '@salesforce/apex/NewPurchaseOrderController.getContactsForAccount';

// Account fields for auto-population
import ACCOUNT_NAME_FIELD from '@salesforce/schema/Account.Name';
import ACCOUNT_TYPE_FIELD from '@salesforce/schema/Account.Type';
import ACCOUNT_SHIPPING_STREET from '@salesforce/schema/Account.ShippingStreet';
import ACCOUNT_SHIPPING_CITY from '@salesforce/schema/Account.ShippingCity';
import ACCOUNT_SHIPPING_STATE from '@salesforce/schema/Account.ShippingState';
import ACCOUNT_SHIPPING_POSTAL_CODE from '@salesforce/schema/Account.ShippingPostalCode';
import ACCOUNT_SHIPPING_COUNTRY from '@salesforce/schema/Account.ShippingCountry';
import ACCOUNT_BILLING_STREET from '@salesforce/schema/Account.BillingStreet';
import ACCOUNT_BILLING_CITY from '@salesforce/schema/Account.BillingCity';
import ACCOUNT_BILLING_STATE from '@salesforce/schema/Account.BillingState';
import ACCOUNT_BILLING_POSTAL_CODE from '@salesforce/schema/Account.BillingPostalCode';
import ACCOUNT_BILLING_COUNTRY from '@salesforce/schema/Account.BillingCountry';
//import ACCOUNT_SYNC_TO_QB from '@salesforce/schema/Account.faxa__Sync_to_QuickBooks__c';

import USER_NAME_FIELD from '@salesforce/schema/User.Name';

const ACCOUNT_FIELDS = [
    ACCOUNT_NAME_FIELD,
    ACCOUNT_TYPE_FIELD,
    ACCOUNT_SHIPPING_STREET,
    ACCOUNT_SHIPPING_CITY,
    ACCOUNT_SHIPPING_STATE,
    ACCOUNT_SHIPPING_POSTAL_CODE,
    ACCOUNT_SHIPPING_COUNTRY,
    ACCOUNT_BILLING_STREET,
    ACCOUNT_BILLING_CITY,
    ACCOUNT_BILLING_STATE,
    ACCOUNT_BILLING_POSTAL_CODE,
    ACCOUNT_BILLING_COUNTRY
];

export default class NewPurchaseOrder extends NavigationMixin(LightningElement) {
    @api recordId; // Account Record Id if launched from Account context

    loading = false;
    saving = false;

    // Purchase Order Header fields
    @track poNumber = '';
    @track vendorId = '';
    @track poDate = '';
    @track opportunityId = '';
    @track status = '';
    @track permitNo = '';
    @track orderId = '';
    vendorAccountType = '';
    vendorAccountLoaded = false;

    // Opportunity lookup state
    @track opportunitySearchTerm = '';
    @track opportunityDropdownOpen = false;
    _selectedOpportunityName = '';
    opportunityBlurTimer;

    // Order lookup state
    @track orderSearchTerm = '';
    @track orderDropdownOpen = false;
    _selectedOrderName = '';
    orderBlurTimer;

    // Address fields
    @track shippingStreet = '';
    @track shippingCity = '';
    @track shippingState = '';
    @track shippingPostalCode = '';
    @track shippingCountry = '';

    // QuickBooks Information
    @track syncToQuickBooks = false;
    @track quickbooksPoId = '';
    @track integrationStatus = '';

    // Picklist options
    @track statusOptions = [];
    @track integrationStatusOptions = [];
    @track classOptions = [];
    @track customerAccountOptions = [];

    // Line items & product finder
    @track lines = [];
    showProductFinder = false;
    productSearchTerm = '';
    productSearchResults = [];
    showProductSearchResults = false;
    disableAddSearchProducts = true;
    addSearchSelectedLabel = 'Add Selected';
    productSearchTimer;
    productSearchLoading = false;
    _activeProductSearchRequest = 0;
    _lastProductSearchTerm = null;
    _ignoreNextFocusSearch = false;
    _pendingSearchSelections = new Map();
    lineCustomerBlurTimer;
    customerSearchTimer;
    _activeCustomerSearchRequest = 0;

    ownerName = '';


    opportunityRawOptions = [];
    orderRawOptions = [];
    showNewOpportunityModal = false;
    showNewOrderModal = false;
    opportunityAccountId = '';
    opportunityContactId = '';
    contactOptions = [];
    contactLoading = false;

    get disableContactSelection() {
        return !this.opportunityAccountId || this.contactLoading;
    }

    get contactPlaceholder() {
        if (!this.opportunityAccountId) {
            return 'Select an Account first';
        }
        if (this.contactLoading) {
            return 'Loading Contacts...';
        }
        if (!this.contactOptions.length) {
            return 'No Contacts found for selected Account';
        }
        return 'Select a Contact';
    }

    orderContactId = '';
    orderContactOptions = [];
    orderContactLoading = false;

    get disableOrderContactSelection() {
        return !this.vendorId || this.orderContactLoading || !this.orderContactOptions || this.orderContactOptions.length === 0;
    }

    get orderContactPlaceholder() {
        if (!this.vendorId) {
            return 'Select an Account first';
        }
        if (this.orderContactLoading) {
            return 'Loading Contacts...';
        }
        if (!this.orderContactOptions || !this.orderContactOptions.length) {
            return 'No Contacts found for selected Account';
        }
        return 'Select a Site Contact';
    }

    @wire(getRelatedRecordsForAccount, { accountId: '$vendorId' })
    wiredRelatedRecords({ error, data }) {
        if (data) {
            this.opportunityRawOptions = data.opportunityOptions || [];
            this.orderRawOptions = data.orderOptions || [];
        } else if (error) {
            console.error('Error fetching related records:', error);
            this.opportunityRawOptions = [];
            this.orderRawOptions = [];
        }
    }

    get selectedOpportunityLabel() {
        if (!this.opportunityId) return '';
        const match = (this.opportunityRawOptions || []).find(opt => opt.value === this.opportunityId);
        if (match) return match.label;
        if (this._selectedOpportunityName) return this._selectedOpportunityName;
        return this.opportunityId;
    }

    get selectedOrderLabel() {
        if (!this.orderId) return '';
        const match = (this.orderRawOptions || []).find(opt => opt.value === this.orderId);
        if (match) return match.label;
        if (this._selectedOrderName) return this._selectedOrderName;
        return this.orderId;
    }

    get hasOpportunitySelected() {
        return Boolean(this.opportunityId);
    }

    get hasOrderSelected() {
        return Boolean(this.orderId);
    }

    get showOpportunityDropdown() {
        return this.opportunityDropdownOpen && !this.saving;
    }

    get showOrderDropdown() {
        return this.orderDropdownOpen && !this.saving;
    }

    get hasAnyDropdownOpen() {
        return (this.showOpportunityDropdown || this.showOrderDropdown) && !this.saving;
    }

    get opportunityElementClass() {
        return `slds-form-element custom-lookup-element custom-lookup-element-opportunity ${
            this.showOpportunityDropdown ? 'custom-lookup-element_open' : ''
        }`;
    }

    get orderElementClass() {
        return `slds-form-element custom-lookup-element custom-lookup-element-order ${
            this.showOrderDropdown ? 'custom-lookup-element_open' : ''
        }`;
    }

    get opportunityComboboxClass() {
        return `slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click ${
            this.showOpportunityDropdown ? 'slds-is-open' : ''
        }`;
    }

    get orderComboboxClass() {
        return `slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click ${
            this.showOrderDropdown ? 'slds-is-open' : ''
        }`;
    }

    get filteredOpportunityOptions() {
        const term = (this.opportunitySearchTerm || '').trim().toLowerCase();
        if (!term) {
            return this.opportunityRawOptions || [];
        }
        return (this.opportunityRawOptions || []).filter(opt =>
            opt.label && opt.label.toLowerCase().includes(term)
        );
    }

    get filteredOrderOptions() {
        const term = (this.orderSearchTerm || '').trim().toLowerCase();
        if (!term) {
            return this.orderRawOptions || [];
        }
        return (this.orderRawOptions || []).filter(opt =>
            opt.label && opt.label.toLowerCase().includes(term)
        );
    }

    get hasNoOpportunityResults() {
        return this.filteredOpportunityOptions.length === 0;
    }

    get hasNoOrderResults() {
        return this.filteredOrderOptions.length === 0;
    }

    get mappedStatusOptions() {
        return (this.statusOptions || []).map(opt => ({
            ...opt,
            isSelected: opt.value === this.status
        }));
    }

    get mappedIntegrationStatusOptions() {
        return (this.integrationStatusOptions || []).map(opt => ({
            ...opt,
            isSelected: opt.value === this.integrationStatus
        }));
    }

    get activeLines() {
        return this.lines
            .filter(line => !line.isDeleted)
            .map(line => {
                const customerMatch = (this.customerAccountOptions || []).find(opt => opt.value === line.customerId);
                const customerName = customerMatch ? customerMatch.label : (line.customerName || line.customerId || '');
                const searchTerm = (line.customerSearchTerm || '').trim().toLowerCase();
                const filteredCustomerOptions = searchTerm
                    ? (this.customerAccountOptions || []).filter(opt => opt.label && opt.label.toLowerCase().includes(searchTerm))
                    : (this.customerAccountOptions || []);

                return {
                    ...line,
                    customerName,
                    hasCustomerSelected: Boolean(line.customerId),
                    showCustomerDropdown: line.openCustomerDropdown === true && !this.saving,
                    filteredCustomerOptions,
                    hasNoCustomerResults: filteredCustomerOptions.length === 0,
                    formattedRate: line.rate == null ? '' : this.formatCurrency(line.rate),
                    formattedTotal: this.formatCurrency(line.total || 0)
                };
            });
    }

    get hasLines() {
        return this.activeLines.length > 0;
    }

    get subtotal() {
        return this.activeLines.reduce((sum, line) => sum + Number(line.total || 0), 0);
    }

    get formattedSubtotal() {
        return this.formatCurrency(this.subtotal);
    }

    get disableSave() {
        return this.saving;
    }

    get saveLabel() {
        return this.saving ? 'Saving...' : 'Save';
    }

    get vendorRecordId() {
        if (this.vendorId && this.vendorId.startsWith('001')) {
            return this.vendorId;
        }
        if (this.recordId && this.recordId.startsWith('001')) {
            return this.recordId;
        }
        return null;
    }

    get orderRecordId() {
        if (this.recordId && this.recordId.startsWith('801')) {
            return this.recordId;
        }
        return null;
    }

    connectedCallback() {
        loadStyle(this, modal);
        this.poDate = new Date().toISOString().substring(0, 10);
        if (this.recordId) {
            if (this.recordId.startsWith('001')) {
                this.vendorId = this.recordId;
            } else if (this.recordId.startsWith('006')) {
                this.opportunityId = this.recordId;
            } else if (this.recordId.startsWith('801')) {
                this.orderId = this.recordId;
            }
        }
        this._handleDocumentClick = this.handleDocumentClick.bind(this);
        document.addEventListener('click', this._handleDocumentClick);
        this.loadPicklists();
    }

    disconnectedCallback() {
        document.removeEventListener('click', this._handleDocumentClick);
        clearTimeout(this.productSearchTimer);
        clearTimeout(this.opportunityBlurTimer);
        clearTimeout(this.orderBlurTimer);
        clearTimeout(this.lineCustomerBlurTimer);
        clearTimeout(this.customerSearchTimer);
    }

    @wire(getRecord, { recordId: USER_ID, fields: [USER_NAME_FIELD] })
    wiredUser({ error, data }) {
        if (data) {
            this.ownerName = data.fields.Name.value;
        } else if (error) {
            console.error('Error fetching user info:', error);
        }
    }

    @wire(getRecord, { recordId: '$vendorRecordId', fields: ACCOUNT_FIELDS })
    wiredAccount({ error, data }) {
        if (data) {
            this.vendorAccountLoaded = true;
            if (!this.vendorId) {
                this.vendorId = this.vendorRecordId;
            }

            this.vendorAccountType = data.fields.Type?.value || '';
            const sStreet = data.fields.ShippingStreet?.value;
            const sCity = data.fields.ShippingCity?.value;
            const sState = data.fields.ShippingState?.value;
            const sPostalCode = data.fields.ShippingPostalCode?.value;
            const sCountry = data.fields.ShippingCountry?.value;

            const bStreet = data.fields.BillingStreet?.value;
            const bCity = data.fields.BillingCity?.value;
            const bState = data.fields.BillingState?.value;
            const bPostalCode = data.fields.BillingPostalCode?.value;
            const bCountry = data.fields.BillingCountry?.value;

            if (!this.shippingStreet) this.shippingStreet = sStreet || bStreet || '';
            if (!this.shippingCity) this.shippingCity = sCity || bCity || '';
            if (!this.shippingState) this.shippingState = sState || bState || '';
            if (!this.shippingPostalCode) this.shippingPostalCode = sPostalCode || bPostalCode || '';
            if (!this.shippingCountry) this.shippingCountry = sCountry || bCountry || '';

            if (data.fields.faxa__Sync_to_QuickBooks__c) {
                this.syncToQuickBooks = data.fields.faxa__Sync_to_QuickBooks__c.value || false;
            }
        } else if (error) {
            console.error('Error fetching account info:', error);
            this.vendorAccountType = '';
            this.vendorAccountLoaded = false;
        }
    }

    @wire(getOrderDetails, { orderId: '$orderRecordId' })
    wiredOrderDetails({ error, data }) {
        if (data) {
            if (data.orderId) {
                this.orderId = data.orderId;
            }
            if (data.orderLabel) {
                this._selectedOrderName = data.orderLabel;
            }
            if (data.accountId) {
                this.vendorId = data.accountId;
            }
            if (data.opportunityId) {
                this.opportunityId = data.opportunityId;
            }
            if (data.shippingStreet) this.shippingStreet = data.shippingStreet;
            if (data.shippingCity) this.shippingCity = data.shippingCity;
            if (data.shippingState) this.shippingState = data.shippingState;
            if (data.shippingPostalCode) this.shippingPostalCode = data.shippingPostalCode;
            if (data.shippingCountry) this.shippingCountry = data.shippingCountry;

            if (data.lines && data.lines.length > 0 && this.lines.length === 0) {
                this.lines = data.lines.map(line => this.normalizeLine(line));
            }
        } else if (error) {
            console.error('Error fetching order details:', error);
        }
    }

    async loadPicklists() {
        try {
            const statusVals = await getPicklistValues({ fieldApiName: 'Purchase_Order_Status__c' });
            if (statusVals && statusVals.length > 0) {
                this.statusOptions = statusVals.map(val => ({ label: val, value: val }));
            } else {
                this.statusOptions = [
                    { label: 'Draft', value: 'Draft' },
                    { label: 'Pending', value: 'Pending' },
                    { label: 'Approved', value: 'Approved' },
                    { label: 'Closed', value: 'Closed' }
                ];
            }
        } catch (e) {
            this.statusOptions = [
                { label: 'Draft', value: 'Draft' },
                { label: 'Pending', value: 'Pending' },
                { label: 'Approved', value: 'Approved' },
                { label: 'Closed', value: 'Closed' }
            ];
        }

        try {
            const syncStatusVals = await getPicklistValues({ fieldApiName: 'QuickBooks_Sync_Status__c' });
            if (syncStatusVals && syncStatusVals.length > 0) {
                this.integrationStatusOptions = syncStatusVals.map(val => ({ label: val, value: val }));
            } else {
                this.integrationStatusOptions = [
                    { label: 'Draft', value: 'Draft' },
                    { label: 'Synced', value: 'Synced' },
                    { label: 'Error', value: 'Error' }
                ];
            }
        } catch (e) {
            this.integrationStatusOptions = [
                { label: 'Draft', value: 'Draft' },
                { label: 'Synced', value: 'Synced' },
                { label: 'Error', value: 'Error' }
            ];
        }

        try {
            const classes = await getClassOptions();
            if (classes && classes.length > 0) {
                this.classOptions = classes;
            } else {
                this.classOptions = [];
            }
        } catch (e) {
            console.error('Error fetching class options:', e);
            this.classOptions = [];
        }

        await this.loadCustomerAccounts('');
    }

    async loadCustomerAccounts(searchTerm = '') {
        const requestId = ++this._activeCustomerSearchRequest;
        try {
            const customers = await getCustomerAccounts({ searchTerm });
            if (requestId !== this._activeCustomerSearchRequest) return;
            this.customerAccountOptions = customers || [];
        } catch (e) {
            if (requestId !== this._activeCustomerSearchRequest) return;
            console.error('Error fetching customer accounts:', e);
            this.customerAccountOptions = [];
        }
    }

    // Change Handlers
    handlePoNumberChange(event) { this.poNumber = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleVendorChange(event) {
        const newVendorId = event.detail.value !== undefined ? event.detail.value : (event.detail.recordId || null);
        if (this.vendorId !== newVendorId) {
            this.vendorId = newVendorId;
            this.vendorAccountType = '';
            this.vendorAccountLoaded = false;
            this.opportunityId = null;
            this.orderId = null;
        }
    }
    handleOptionMouseDown(event) {
        event.preventDefault();
    }

    handleCloseAllDropdowns(event) {
        if (event) {
            event.stopPropagation();
        }
        this.opportunityDropdownOpen = false;
        this.orderDropdownOpen = false;
    }

    handleOpportunityFocus(event) {
        clearTimeout(this.opportunityBlurTimer);
        this.opportunityDropdownOpen = true;
        this.orderDropdownOpen = false;
    }

    handleOpportunityClick(event) {
        clearTimeout(this.opportunityBlurTimer);
        this.opportunityDropdownOpen = true;
        this.orderDropdownOpen = false;
    }

    handleOpportunitySearchChange(event) {
        clearTimeout(this.opportunityBlurTimer);
        this.opportunitySearchTerm = event.target.value;
        this.opportunityDropdownOpen = true;
    }

    handleOpportunityBlur() {
        clearTimeout(this.opportunityBlurTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.opportunityBlurTimer = setTimeout(() => {
            this.opportunityDropdownOpen = false;
        }, 200);
    }

    handleSelectOpportunity(event) {
        event?.stopPropagation();
        clearTimeout(this.opportunityBlurTimer);
        const val = event.currentTarget.dataset.value;
        const match = (this.opportunityRawOptions || []).find(opt => opt.value === val);
        this.opportunityId = val;
        if (match) {
            this._selectedOpportunityName = match.label;
        }
        this.opportunityDropdownOpen = false;
        this.opportunitySearchTerm = '';
    }

    handleClearOpportunity(event) {
        event?.stopPropagation();
        clearTimeout(this.opportunityBlurTimer);
        this.opportunityId = '';
        this._selectedOpportunityName = '';
        this.opportunitySearchTerm = '';
        this.opportunityDropdownOpen = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const input = this.template.querySelector('.custom-lookup-element-opportunity lightning-input');
            if (input) {
                input.focus();
            }
        });
    }

    handleNewOpportunity(event) {
        event?.stopPropagation();
        clearTimeout(this.opportunityBlurTimer);
        this.opportunityDropdownOpen = false;
        this.opportunityAccountId = this.vendorId || '';
        this.opportunityContactId = '';
        this.showNewOpportunityModal = true;
        this.loadOpportunityContacts();
    }

    handleCloseOpportunityModal() {
        this.showNewOpportunityModal = false;
    }

    handleOppAccountChange(event) {
        this.opportunityAccountId = event.detail.value || event.target.value || '';
        this.opportunityContactId = '';
        this.loadOpportunityContacts();
    }

    handleOppContactChange(event) {
        this.opportunityContactId = event.detail.value || '';
    }

    async loadOpportunityContacts() {
        const accountId = this.opportunityAccountId;
        this.contactOptions = [];

        if (!accountId) {
            return;
        }

        this.contactLoading = true;
        try {
            const contacts = await getContactsForAccount({ accountId });
            if (this.opportunityAccountId !== accountId) {
                return;
            }
            this.contactOptions = (contacts || []).map(contact => ({
                label: contact.label,
                value: contact.value
            }));
        } catch (error) {
            this.showToast('Error loading Contacts', this.extractErrorMessage(error), 'error');
        } finally {
            if (this.opportunityAccountId === accountId) {
                this.contactLoading = false;
            }
        }
    }

    handleSubmitOpportunity(event) {
        if (!this.opportunityContactId) {
            event.preventDefault();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: 'Primary Contact is required. Please select a contact for the selected Account.',
                    variant: 'error'
                })
            );
        }
    }

    handleOpportunityCreated(event) {
        const newOppId = event.detail.id;
        const fields = event.detail.fields || {};
        const newOppName = fields.Name?.value || 'New Opportunity';

        this.opportunityId = newOppId;
        this._selectedOpportunityName = newOppName;

        if (!this.opportunityRawOptions.some(opt => opt.value === newOppId)) {
            this.opportunityRawOptions = [
                { label: newOppName, value: newOppId },
                ...this.opportunityRawOptions
            ];
        }

        this.showNewOpportunityModal = false;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Success',
                message: 'Opportunity created successfully',
                variant: 'success'
            })
        );
    }

    handleOpportunityError(event) {
        console.error('Error creating Opportunity:', event.detail);
    }

    handleOrderFocus(event) {
        clearTimeout(this.orderBlurTimer);
        this.orderDropdownOpen = true;
        this.opportunityDropdownOpen = false;
    }

    handleOrderClick(event) {
        clearTimeout(this.orderBlurTimer);
        this.orderDropdownOpen = true;
        this.opportunityDropdownOpen = false;
    }

    handleOrderSearchChange(event) {
        clearTimeout(this.orderBlurTimer);
        this.orderSearchTerm = event.target.value;
        this.orderDropdownOpen = true;
    }

    handleOrderBlur() {
        clearTimeout(this.orderBlurTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.orderBlurTimer = setTimeout(() => {
            this.orderDropdownOpen = false;
        }, 200);
    }

    handleSelectOrder(event) {
        event?.stopPropagation();
        clearTimeout(this.orderBlurTimer);
        const val = event.currentTarget.dataset.value;
        const match = (this.orderRawOptions || []).find(opt => opt.value === val);
        this.orderId = val;
        if (match) {
            this._selectedOrderName = match.label;
        }
        this.orderDropdownOpen = false;
        this.orderSearchTerm = '';
    }

    handleClearOrder(event) {
        event?.stopPropagation();
        clearTimeout(this.orderBlurTimer);
        this.orderId = '';
        this._selectedOrderName = '';
        this.orderSearchTerm = '';
        this.orderDropdownOpen = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const input = this.template.querySelector('.custom-lookup-element-order lightning-input');
            if (input) {
                input.focus();
            }
        });
    }

    handleNewOrder(event) {
        event?.stopPropagation();
        clearTimeout(this.orderBlurTimer);
        this.orderDropdownOpen = false;
        this.orderContactId = '';
        this.orderContactOptions = [];
        this.showNewOrderModal = true;
        this.loadOrderContacts();
    }

    handleCloseOrderModal() {
        this.showNewOrderModal = false;
        this.orderContactId = '';
        this.orderContactOptions = [];
    }

    async loadOrderContacts() {
        const accountId = this.vendorId;
        this.orderContactOptions = [];
        if (!accountId) {
            return;
        }

        this.orderContactLoading = true;
        try {
            const contacts = await getContactsForAccount({ accountId });
            if (this.vendorId !== accountId) {
                return;
            }
            this.orderContactOptions = (contacts || []).map(contact => ({
                label: contact.label,
                value: contact.value
            }));
        } catch (error) {
            console.error('Error loading Order Site Contacts:', error);
        } finally {
            if (this.vendorId === accountId) {
                this.orderContactLoading = false;
            }
        }
    }

    handleOrderContactChange(event) {
        this.orderContactId = event.detail.value || '';
    }

    handleOrderCreated(event) {
        const newOrderId = event.detail.id;
        const fields = event.detail.fields || {};
        const orderNumber = fields.OrderNumber?.value || '';
        const orderName = fields.Name?.value || '';
        const label = orderNumber && orderName ? `${orderNumber} - ${orderName}` : (orderNumber || orderName || 'New Order');

        this.orderId = newOrderId;
        this._selectedOrderName = label;

        if (!this.orderRawOptions.some(opt => opt.value === newOrderId)) {
            this.orderRawOptions = [
                { label: label, value: newOrderId },
                ...this.orderRawOptions
            ];
        }

        this.showNewOrderModal = false;
        this.orderContactId = '';
        this.orderContactOptions = [];
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Success',
                message: 'Order created successfully',
                variant: 'success'
            })
        );
    }

    handleOrderError(event) {
        console.error('Error creating Order:', event.detail);
    }

    handleStatusChange(event) { this.status = event.detail.value; }
    handlePermitNoChange(event) { this.permitNo = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleStreetChange(event) { this.shippingStreet = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleCityChange(event) { this.shippingCity = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleStateChange(event) { this.shippingState = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handlePostalCodeChange(event) { this.shippingPostalCode = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleCountryChange(event) { this.shippingCountry = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleSyncChange(event) { this.syncToQuickBooks = event.target.checked; }
    handleQbPoIdChange(event) { this.quickbooksPoId = event.detail.value !== undefined ? event.detail.value : event.target.value; }
    handleIntegrationStatusChange(event) { this.integrationStatus = event.target.value; }

    handleDocumentClick(event) {
        const path = event.composedPath ? event.composedPath() : [];

        if (this.showProductFinder) {
            const productFinder = this.template.querySelector('.product-finder');
            if (productFinder && !path.includes(productFinder) && !productFinder.contains(event.target)) {
                this.closeProductFinder();
            }
        }

        if (this.opportunityDropdownOpen) {
            const oppElem = this.template.querySelector('.custom-lookup-element-opportunity');
            if (!oppElem || (!path.includes(oppElem) && !oppElem.contains(event.target))) {
                this.opportunityDropdownOpen = false;
            }
        }

        if (this.orderDropdownOpen) {
            const orderElem = this.template.querySelector('.custom-lookup-element-order');
            if (!orderElem || (!path.includes(orderElem) && !orderElem.contains(event.target))) {
                this.orderDropdownOpen = false;
            }
        }

        const isLineCustomerClick = path.some(node => node.classList && node.classList.contains('line-customer-cell'));
        if (!isLineCustomerClick) {
            clearTimeout(this.lineCustomerBlurTimer);
            this.closeLineCustomerDropdowns();
        }
    }

    // Product Finder Logic
    handleShowProducts(event) {
        event?.stopPropagation();
        if (this.showProductFinder) return;
        this.openProductFinder();
    }

    openProductFinder() {
        this.clearPendingSearchSelections();
        this.showProductFinder = true;
        this.runProductSearch(this.productSearchTerm || '');
        this._ignoreNextFocusSearch = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const searchInput = this.template.querySelector('.product-finder lightning-input');
            if (searchInput) {
                searchInput.focus();
            }
        });
    }

    closeProductFinder() {
        this.showProductFinder = false;
        clearTimeout(this.productSearchTimer);
        this.productSearchTerm = '';
        this.productSearchResults = [];
        this.productSearchLoading = false;
        this._activeProductSearchRequest++;
        this._lastProductSearchTerm = null;
        this.clearPendingSearchSelections();
        this.showProductSearchResults = false;
    }

    handleProductSearchFocus() {
        if (this._ignoreNextFocusSearch) {
            this._ignoreNextFocusSearch = false;
            return;
        }
        if (!this.showProductFinder) {
            this.showProductFinder = true;
        }
        this.runProductSearch(this.productSearchTerm || '');
    }

    handleProductSearch(event) {
        this.productSearchTerm = event.target.value;
        clearTimeout(this.productSearchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.productSearchTimer = setTimeout(() => this.runProductSearch(this.productSearchTerm), 300);
    }

    runProductSearch(searchTerm) {
        const normalizedTerm = (searchTerm || '').trim();
        if (normalizedTerm === this._lastProductSearchTerm && this.productSearchResults.length > 0) {
            this.refreshSearchProductAvailability();
            this.showProductSearchResults = true;
            return;
        }

        this._lastProductSearchTerm = normalizedTerm;
        const requestId = ++this._activeProductSearchRequest;
        this.productSearchLoading = true;

        searchStandardProducts({ searchTerm: normalizedTerm })
            .then((rows) => {
                if (requestId !== this._activeProductSearchRequest) return;
                this.productSearchResults = (rows || []).map((product) =>
                    this.mapSearchProductResult({
                        ...product,
                        id: product.pricebookEntryId || product.productId,
                        pricebookEntryId: product.pricebookEntryId || product.productId,
                        productCode: product.productCode || '',
                        description: product.description || ''
                    })
                );
                this.showProductSearchResults = this.productSearchResults.length > 0;
                this.updateAddSelectedButtonState();
            })
            .catch((error) => {
                if (requestId !== this._activeProductSearchRequest) return;
                this.showProductSearchResults = false;
                this.productSearchResults = [];
                this.showToast('Product search failed', this.extractErrorMessage(error), 'error');
            })
            .finally(() => {
                if (requestId === this._activeProductSearchRequest) {
                    this.productSearchLoading = false;
                }
            });
    }

    handleSearchProductSelection(event) {
        const pbeId = event.currentTarget.dataset.pbeId;
        const checked = event.target.checked;
        const targetProduct = this.productSearchResults.find((product) => product.pricebookEntryId === pbeId || product.id === pbeId);

        if (targetProduct) {
            this.setPendingSearchSelection(targetProduct, checked);
        }

        this.productSearchResults = this.productSearchResults.map((product) => ({
            ...product,
            isSelected: (product.pricebookEntryId === pbeId || product.id === pbeId) ? checked : product.isSelected
        }));
        this.updateAddSelectedButtonState();
    }

    handleCancelProductSearchResults(event) {
        event?.stopPropagation();
        this.showProductSearchResults = false;
    }

    handleAddSearchSelectedProducts() {
        const pendingSelections = this.getPendingSearchSelections();

        if (!pendingSelections.length) return;

        const newLines = pendingSelections.map((product) =>
            this.normalizeLine({
                key: `line-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`,
                productId: product.productId || product.pricebookEntryId || product.id,
                productName: product.productName,
                productCode: product.productCode,
                quickBooksItemId: product.quickBooksItemId,
                description: product.description,
                quantity: 1,
                rate: product.unitPrice,
                classId: '',
                customerId: '',
                isDeleted: false
            })
        );
        this.lines = [...this.lines, ...newLines];
        this.clearPendingSearchSelections();
        this.closeProductFinder();
    }

    clearPendingSearchSelections() {
        this._pendingSearchSelections.clear();
    }

    setPendingSearchSelection(product, selected) {
        const key = product?.productId || product?.pricebookEntryId || product?.id;
        if (!key) return;
        if (selected) {
            this._pendingSearchSelections.set(key, {
                id: product.id || key,
                pricebookEntryId: product.pricebookEntryId || key,
                productId: product.productId || key,
                productName: product.productName,
                productCode: product.productCode || '',
                quickBooksItemId: product.quickBooksItemId || '',
                description: product.description || '',
                unitPrice: product.unitPrice,
                cost: product.cost
            });
        } else {
            this._pendingSearchSelections.delete(key);
        }
    }

    getPendingSearchSelections() {
        return Array.from(this._pendingSearchSelections.values());
    }

    mapSearchProductResult(product) {
        const key = product.productId || product.pricebookEntryId || product.id;
        const isPendingSelected = this._pendingSearchSelections.has(key);
        return {
            ...product,
            pricebookEntryId: product.pricebookEntryId || product.productId || product.id,
            isSelected: isPendingSelected,
            isCheckboxDisabled: this.saving,
            rowClass: 'product-search-result',
            formattedCost: this.formatCurrency(product.cost),
            formattedSalesPrice: this.formatCurrency(product.unitPrice),
            productDescription: product.description || ''
        };
    }

    refreshSearchProductAvailability() {
        if (!this.productSearchResults.length) return;
        this.productSearchResults = this.productSearchResults.map((product) =>
            this.mapSearchProductResult(product)
        );
        this.updateAddSelectedButtonState();
    }

    updateAddSelectedButtonState() {
        const selectedCount = this.getPendingSearchSelections().length;
        this.disableAddSearchProducts = selectedCount === 0;
        this.addSearchSelectedLabel = selectedCount
            ? `Add Selected (${selectedCount})`
            : 'Add Selected';
    }

    handleProductFinderClick(event) {
        event.stopPropagation();
    }

    // Line Editing Logic
    handleLineChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        let value = event.detail.value;

        if (field === 'quantity' || field === 'rate') {
            value = Number(value);
        }

        this.lines = this.lines.map((line) =>
            line.key === key
                ? this.normalizeLine({ ...line, [field]: value })
                : line
        );
    }

    handleLineCustomerFocus(event) {
        clearTimeout(this.lineCustomerBlurTimer);
        const key = event.target.dataset.key;
        const searchTerm = event.target.value || '';
        this.opportunityDropdownOpen = false;
        this.orderDropdownOpen = false;
        this.lines = this.lines.map(line =>
            line.key === key ? { ...line, openCustomerDropdown: true } : { ...line, openCustomerDropdown: false }
        );
        this.loadCustomerAccounts(searchTerm);
    }

    handleLineCustomerSearchChange(event) {
        clearTimeout(this.lineCustomerBlurTimer);
        clearTimeout(this.customerSearchTimer);
        const key = event.target.dataset.key;
        const value = event.target.value;
        this.lines = this.lines.map(line =>
            line.key === key ? { ...line, customerSearchTerm: value, openCustomerDropdown: true } : line
        );
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.customerSearchTimer = setTimeout(() => {
            this.loadCustomerAccounts(value || '');
        }, 300);
    }

    handleLineCustomerBlur() {
        clearTimeout(this.lineCustomerBlurTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.lineCustomerBlurTimer = setTimeout(() => {
            this.closeLineCustomerDropdowns();
        }, 200);
    }

    handleSelectLineCustomer(event) {
        event?.stopPropagation();
        clearTimeout(this.lineCustomerBlurTimer);
        const key = event.currentTarget.dataset.key;
        const value = event.currentTarget.dataset.value;
        const label = event.currentTarget.dataset.label;
        this.lines = this.lines.map(line =>
            line.key === key
                ? this.normalizeLine({ ...line, customerId: value, customerName: label, customerSearchTerm: '', openCustomerDropdown: false })
                : line
        );
    }

    handleClearLineCustomer(event) {
        event?.stopPropagation();
        clearTimeout(this.lineCustomerBlurTimer);
        const key = event.currentTarget.dataset.key;
        this.lines = this.lines.map(line =>
            line.key === key
                ? this.normalizeLine({ ...line, customerId: '', customerName: '', customerSearchTerm: '', openCustomerDropdown: true })
                : line
        );
        this.loadCustomerAccounts('');
    }

    closeLineCustomerDropdowns() {
        this.lines = this.lines.map(line =>
            line.openCustomerDropdown ? { ...line, openCustomerDropdown: false } : line
        );
    }

    handleRemoveLine(event) {
        const key = event.currentTarget.dataset.key;
        this.lines = this.lines.map((line) =>
            line.key === key ? { ...line, isDeleted: true } : line
        );
        this.refreshSearchProductAvailability();
    }

    normalizeLine(line) {
        const quantity = Number(line.quantity || 0);
        const rate = Number(line.rate || 0);
        return {
            ...line,
            quantity,
            rate,
            classId: line.classId || '',
            customerId: line.customerId || '',
            total: Number((quantity * rate).toFixed(2)),
            isDeleted: line.isDeleted === true
        };
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: 'USD'
        }).format(Number(value || 0));
    }

    // Validation & Save Logic
    validateBeforeSave() {
        const poCmp = this.template.querySelector('lightning-input[data-field="poNumber"]');
        if (poCmp && poCmp.value) {
            this.poNumber = poCmp.value;
        }

        const vendorCmp = this.template.querySelector('lightning-record-picker[label="Vendor"]');
        if (vendorCmp && vendorCmp.value) {
            this.vendorId = vendorCmp.value;
        }

        const streetCmp = this.template.querySelector('lightning-textarea[data-field="shippingStreet"]');
        if (streetCmp && streetCmp.value !== undefined) {
            this.shippingStreet = streetCmp.value;
        }

        const cityCmp = this.template.querySelector('lightning-input[data-field="shippingCity"]');
        if (cityCmp && cityCmp.value !== undefined) {
            this.shippingCity = cityCmp.value;
        }

        const stateCmp = this.template.querySelector('lightning-input[data-field="shippingState"]');
        if (stateCmp && stateCmp.value !== undefined) {
            this.shippingState = stateCmp.value;
        }

        const zipCmp = this.template.querySelector('lightning-input[data-field="shippingPostalCode"]');
        if (zipCmp && zipCmp.value !== undefined) {
            this.shippingPostalCode = zipCmp.value;
        }

        const countryCmp = this.template.querySelector('lightning-input[data-field="shippingCountry"]');
        if (countryCmp && countryCmp.value !== undefined) {
            this.shippingCountry = countryCmp.value;
        }

        const qbIdCmp = this.template.querySelector('lightning-input[data-field="quickbooksPoId"]');
        if (qbIdCmp && qbIdCmp.value !== undefined) {
            this.quickbooksPoId = qbIdCmp.value;
        }

        const statusSelect = this.template.querySelector('#status-select');
        if (statusSelect && statusSelect.value !== undefined) {
            this.status = statusSelect.value;
        }

        const integrationSelect = this.template.querySelector('#integration-select');
        if (integrationSelect && integrationSelect.value !== undefined) {
            this.integrationStatus = integrationSelect.value;
        }

        if (!this.poNumber || !this.poNumber.trim()) {
            return 'PO Number is required.';
        }
        if (!this.vendorId) {
            return 'Vendor is required.';
        }
        if (this.vendorAccountLoaded && this.vendorAccountType !== 'Vendor') {
            return 'Purchase Orders can only be created for Accounts with Type = Vendor.';
        }
        if (!this.activeLines || this.activeLines.length === 0) {
            return 'Please add at least one line item before saving the Purchase Order.';
        }

        for (const line of this.activeLines) {
            if (!line.productId) {
                return 'Each line item must have a product.';
            }
            if (!line.quantity || Number(line.quantity) <= 0) {
                return 'Quantity must be greater than zero.';
            }
            if (line.rate == null || Number(line.rate) < 0) {
                return 'Rate cannot be negative.';
            }
        }

        const quickBooksValidationError = this.validateProductQuickBooksItemIds();
        if (quickBooksValidationError) {
            return quickBooksValidationError;
        }

        return null;
    }

    validateProductQuickBooksItemIds() {
        const invalidProductNames = [
            ...new Set(
                this.activeLines
                    .filter(line => !line.quickBooksItemId || !String(line.quickBooksItemId).trim())
                    .map(line => line.productName || line.productCode || line.productId || 'Unknown Product')
            )
        ];

        if (!invalidProductNames.length) {
            return null;
        }

        const productNames = invalidProductNames.map(name => `"${name}"`).join(', ');
        if (invalidProductNames.length === 1) {
            return `Cannot save Purchase Order. The product ${productNames} is missing a QuickBooks Item ID (faxa__QuickBooks_Item_Id__c). Please update the product and try again.`;
        }
        return `Cannot save Purchase Order. The products ${productNames} are missing a QuickBooks Item ID (faxa__QuickBooks_Item_Id__c). Please update the products and try again.`;
    }

    buildPayload() {
        return {
            poNumber: this.poNumber,
            vendorId: this.vendorId,
            poDate: this.poDate,
            opportunityId: this.opportunityId,
            status: this.status,
            permitNo: this.permitNo,
            orderId: this.orderId,
            shippingStreet: this.shippingStreet,
            shippingCity: this.shippingCity,
            shippingState: this.shippingState,
            shippingPostalCode: this.shippingPostalCode,
            shippingCountry: this.shippingCountry,
            syncToQuickBooks: this.syncToQuickBooks,
            quickbooksPoId: this.quickbooksPoId,
            integrationStatus: this.integrationStatus,
            lines: this.lines
                .filter(l => !l.isDeleted)
                .map(l => ({
                    key: l.key,
                    productId: l.productId,
                    productName: l.productName,
                    productCode: l.productCode,
                    quickBooksItemId: l.quickBooksItemId,
                    quantity: l.quantity,
                    rate: l.rate,
                    amount: l.total || (l.quantity * l.rate),
                    description: l.description,
                    classId: l.classId || null,
                    customerId: l.customerId || null,
                    isDeleted: false
                }))
        };
    }

    async handleSave() {
        const validationError = this.validateBeforeSave();
        if (validationError) {
            this.showToast('Validation Error', validationError, 'error');
            return;
        }

        this.saving = true;
        try {
            const payload = this.buildPayload();
            const result = await createPurchaseOrder({ request: payload });

            this.showToast('Success', 'Purchase Order created successfully.', 'success');

            if (result && result.purchaseOrderId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: result.purchaseOrderId,
                        objectApiName: 'faxa__Purchase_Order__c',
                        actionName: 'view'
                    }
                });
            }

            setTimeout(() => {
                this.dispatchEvent(new CloseActionScreenEvent());
            }, 0);
        } catch (error) {
            this.showToast('Error creating Purchase Order', this.extractErrorMessage(error), 'error');
        } finally {
            this.saving = false;
        }
    }

    async handleSaveAndNew() {
        const validationError = this.validateBeforeSave();
        if (validationError) {
            this.showToast('Validation Error', validationError, 'error');
            return;
        }

        this.saving = true;
        try {
            const payload = this.buildPayload();
            await createPurchaseOrder({ request: payload });

            this.showToast('Success', 'Purchase Order created successfully.', 'success');

            // Reset form
            this.poNumber = '';
            this.permitNo = '';
            this.opportunityId = '';
            this.orderId = '';
            this.quickbooksPoId = '';
            this.status = '';
            this.integrationStatus = '';
            this.lines = [];

            const statusSelect = this.template.querySelector('#status-select');
            if (statusSelect) statusSelect.value = '';
            const integrationSelect = this.template.querySelector('#integration-select');
            if (integrationSelect) integrationSelect.value = '';

        } catch (error) {
            this.showToast('Error creating Purchase Order', this.extractErrorMessage(error), 'error');
        } finally {
            this.saving = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractErrorMessage(error) {
        if (!error) return 'Unknown error.';
        if (Array.isArray(error.body)) return error.body.map(e => e.message).join(', ');
        if (error.body?.message) return error.body.message;
        if (error.message) return error.message;
        return 'Unknown error.';
    }
}