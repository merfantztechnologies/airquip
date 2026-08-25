import { api, LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { loadStyle } from 'lightning/platformResourceLoader';

import modal from '@salesforce/resourceUrl/modalPopup';
import getWorkspace from '@salesforce/apex/OrderInvoiceWorkspaceController.getWorkspace';
import searchStandardProducts from '@salesforce/apex/OrderInvoiceWorkspaceController.searchStandardProducts';
import createDraftInvoice from '@salesforce/apex/OrderInvoiceWorkspaceController.createDraftInvoice';
import getInvoiceStatusValues from '@salesforce/apex/OrderInvoiceWorkspaceController.getInvoiceStatusValues';
import getInvoiceClassValues from '@salesforce/apex/OrderInvoiceWorkspaceController.getInvoiceClassValues';
import getInvoiceTermsValues from '@salesforce/apex/OrderInvoiceWorkspaceController.getInvoiceTermsValues';
import getInvoiceJobCategoryValues from '@salesforce/apex/OrderInvoiceWorkspaceController.getInvoiceJobCategoryValues';

export default class OrderInvoiceWorkspace extends NavigationMixin(LightningElement) {
    _recordId;
    loading = true;
    saving = false;
    productSearchTerm = '';
    productSearchResults = [];
    showProductSearchResults = false;
    disableAddSearchProducts = true;
    addSearchSelectedLabel = 'Add Selected';
    productSearchTimer;
    showProductFinder = false;
    productSearchLoading = false;
    _activeProductSearchRequest = 0;
    _lastProductSearchTerm = null;
    _ignoreNextFocusSearch = false;
    _pendingSearchSelections = new Map();

    @track header = {};
    @track lines = [];
    workspace;

    @track statusOptions = [];
    @track termsOptions = [];
    @track jobCategoryOptions = [];
    @track classOptions = [];

    showNewContactModal = false;
    creatingContact = false;
    termsDropdownOpen = false;
    jobCategoryDropdownOpen = false;
    classDropdownOpen = false;
    contactPickerKey = 'contact-picker';
    newContactFormKey = 'new-contact-form';

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        if (value) this.loadWorkspace();
    }

    connectedCallback() {
        loadStyle(this, modal);
        this._handleOverlayScrollClose = this.handleOverlayScrollClose.bind(this);
        this._handleDocumentClick = this.handleDocumentClick.bind(this);
        this._handleDocumentPointerDown = this.handleDocumentPointerDown.bind(this);
        window.addEventListener('scroll', this._handleOverlayScrollClose, true);
        document.addEventListener('click', this._handleDocumentClick);
        document.addEventListener('mousedown', this._handleDocumentPointerDown, true);
        document.addEventListener('touchstart', this._handleDocumentPointerDown, true);
        if (this.recordId) this.loadWorkspace();
    }

    disconnectedCallback() {
        window.removeEventListener('scroll', this._handleOverlayScrollClose, true);
        document.removeEventListener('click', this._handleDocumentClick);
        document.removeEventListener('mousedown', this._handleDocumentPointerDown, true);
        document.removeEventListener('touchstart', this._handleDocumentPointerDown, true);
        clearTimeout(this.productSearchTimer);
    }

    // ====================== GETTERS ======================
    get orderNumber() { return this.workspace?.orderNumber || ''; }
    get orderStatus() { return this.workspace?.orderStatus || ''; }
    get accountName() { return this.workspace?.accountName || ''; }
    get ownerName() { return this.workspace?.ownerName || ''; }

    get activeLines() {
        return this.lines
            .filter(line => !line.isDeleted)
            .map(line => ({
                ...line,
                formattedCost: line.cost == null ? '' : this.formatCurrency(line.cost),
                formattedTotal: this.formatCurrency(line.total || 0)
            }));
    }

    get hasLines() { return this.activeLines.length > 0; }

    get subtotal() {
        return this.activeLines.reduce((sum, line) => sum + Number(line.total || 0), 0);
    }

    get tax() {
        return this.activeLines.reduce((sum, line) => sum + Number(line.taxAmount || 0), 0);
    }

    get grandTotal() { return this.subtotal + this.tax; }
    get paymentReceived() { return 0; }
    get amountDue() { return this.grandTotal - this.paymentReceived; }

    get formattedSubtotal() { return this.formatCurrency(this.subtotal); }
    get formattedTax() { return this.formatCurrency(this.tax); }
    get formattedGrandTotal() { return this.formatCurrency(this.grandTotal); }
    get formattedPaymentReceived() { return this.formatCurrency(this.paymentReceived); }
    get formattedAmountDue() { return this.formatCurrency(this.amountDue); }

    get disableSave() { return this.saving || !this.hasLines; }
    get saveLabel() { return this.saving ? 'Saving...' : 'Save'; }

    get statusSelectOptions() {
        const current = this.header?.status;
        return (this.statusOptions || []).map((option) => ({
            ...option,
            isSelected: option.value === current
        }));
    }

    get classSelectOptions() {
        const current = this.header?.invoiceClass;
        return (this.classOptions || []).map((option) => ({
            ...option,
            isSelected: option.value === current,
            optionClass: option.value === current
                ? 'terms-select-option terms-select-option_selected'
                : 'terms-select-option'
        }));
    }

    get classDisplayLabel() {
        const current = this.header?.invoiceClass;
        if (!current) {
            return '--None--';
        }
        const match = (this.classOptions || []).find((option) => option.value === current);
        return match ? match.label : current;
    }

    get classNoneSelected() {
        return !this.header?.invoiceClass;
    }

    get classNoneOptionClass() {
        return this.classNoneSelected
            ? 'terms-select-option terms-select-option_selected'
            : 'terms-select-option';
    }

    get jobCategoryDisplayLabel() {
        const current = this.header?.jobCategory;
        if (!current) {
            return '--None--';
        }
        const match = (this.jobCategoryOptions || []).find((option) => option.value === current);
        return match ? match.label : current;
    }

    get jobCategoryNoneSelected() {
        return !this.header?.jobCategory;
    }

    get jobCategoryNoneOptionClass() {
        return this.jobCategoryNoneSelected
            ? 'terms-select-option terms-select-option_selected'
            : 'terms-select-option';
    }

    get jobCategorySelectOptions() {
        const current = this.header?.jobCategory;
        return (this.jobCategoryOptions || []).map((option) => ({
            ...option,
            isSelected: option.value === current,
            optionClass: option.value === current
                ? 'terms-select-option terms-select-option_selected'
                : 'terms-select-option'
        }));
    }

    get termsDisplayLabel() {
        const current = this.header?.terms;
        if (!current) {
            return 'Select terms';
        }
        const match = (this.termsOptions || []).find((option) => option.value === current);
        return match ? match.label : current;
    }

    get termsSelectOptions() {
        const current = this.header?.terms;
        return (this.termsOptions || []).map((option) => ({
            ...option,
            isSelected: option.value === current,
            optionClass: option.value === current
                ? 'terms-select-option terms-select-option_selected'
                : 'terms-select-option'
        }));
    }

    get contactFilter() {
        const accountId = this.workspace?.accountId;
        if (!accountId) {
            return { criteria: [] };
        }
        return {
            criteria: [
                {
                    fieldPath: 'AccountId',
                    operator: 'eq',
                    value: accountId
                }
            ],
            filterLogic: '1'
        };
    }

    get contactMatchingInfo() {
        return {
            primaryField: { fieldPath: 'Name' }
        };
    }

    get contactDisplayInfo() {
        return {
            additionalFields: ['Email']
        };
    }

    get salesPersonMatchingInfo() {
        return {
            primaryField: { fieldPath: 'Name' },
            additionalFields: [{ fieldPath: 'Email' }]
        };
    }

    get salesPersonDisplayInfo() {
        return {
            additionalFields: ['Email']
        };
    }

    get accountIdForNewContact() {
        return this.workspace?.accountId;
    }

    get isContactPickerDisabled() {
        return !this.workspace?.accountId || this.saving;
    }

    get isNewContactButtonDisabled() {
        return !this.workspace?.accountId || this.saving || this.creatingContact;
    }

    get showNewContactButton() {
        return !this.header?.contactId;
    }

    // ====================== LIFECYCLE & DATA LOADING ======================
    async loadWorkspace() {
        this.loading = true;
        try {
            const data = await getWorkspace({ orderId: this.recordId });
            this.workspace = data;
            this.header = {
                status: 'Draft',
                invoiceClass: data.invoiceClass || null,
                contactId: data.contactId,
                salesPersonId: data.ownerId,
                jobCategory: data.jobCategory || null,
                transactionDate: data.transactionDate,
                dueDate: data.dueDate,
                poNumber: data.poNumber,
                terms: data.terms,
                billingStreet: data.billingStreet,
                billingCity: data.billingCity,
                billingState: data.billingState,
                billingPostalCode: data.billingPostalCode,
                jobDescription: '',
                jobDetail: '',
                engineerCompletionNotes: '',
                syncToQuickBooks: data.syncToQuickBooks,
                sendToQuickBooks: data.sendToQuickBooks,
                quickBooksInvoiceId: data.quickBooksInvoiceId
            };

            this.lines = (data.lines || []).map(line => this.normalizeLine(line));
            await Promise.all([
                this.loadStatusOptions(),
                this.loadClassOptions(),
                this.loadTermsOptions(),
                this.loadJobCategoryOptions()
            ]);
        } catch (error) {
            this.showToast('Unable to load invoice workspace', this.extractErrorMessage(error), 'error');
        } finally {
            this.loading = false;
        }
    }

 // ====================== Picklists ======================

    async loadStatusOptions() {
        try {
            const result = await getInvoiceStatusValues();

            this.statusOptions = (result || []).map((status) => ({
                label: status,
                value: status
            }));
        } catch (error) {
            this.showToast(
                'Unable to load status values',
                this.extractErrorMessage(error),
                'error'
            );
        }
    }
    async loadClassOptions() {
        try {
            const result = await getInvoiceClassValues();

            this.classOptions = (result || []).map((class1) => ({
                label: class1,
                value: class1
            }));
        } catch (error) {
            this.showToast(
                'Unable to load Class values',
                this.extractErrorMessage(error),
                'error'
            );
        }
    }

    async loadTermsOptions() {
        try {
            const result = await getInvoiceTermsValues();

            this.termsOptions = (result || []).map((term) => ({
                label: term,
                value: term
            }));
        } catch (error) {
            this.showToast(
                'Unable to load terms values',
                this.extractErrorMessage(error),
                'error'
            );
        }
    }

    async loadJobCategoryOptions() {
        try {
            const result = await getInvoiceJobCategoryValues();

            this.jobCategoryOptions = (result || []).map((category) => ({
                label: category,
                value: category
            }));
        } catch (error) {
            this.showToast(
                'Unable to load job category values',
                this.extractErrorMessage(error),
                'error'
            );
        }
    }

    // ====================== EVENT HANDLERS ======================
    handleHeaderChange(event) {
        const field = event.target.dataset.field;
        this.header = { ...this.header, [field]: event.detail.value };
    }

    handleNativeSelectChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        this.header = {
            ...this.header,
            [field]: value || null
        };
    }

    toggleTermsDropdown(event) {
        event.stopPropagation();
        if (this.saving) {
            return;
        }
        this.jobCategoryDropdownOpen = false;
        this.termsDropdownOpen = !this.termsDropdownOpen;
    }

    handleTermsOptionSelect(event) {
        event.stopPropagation();
        const value = event.currentTarget.dataset.value;
        this.header = {
            ...this.header,
            terms: value || null
        };
        this.termsDropdownOpen = false;
    }

    toggleJobCategoryDropdown(event) {
        event.stopPropagation();
        if (this.saving) {
            return;
        }
        this.termsDropdownOpen = false;
        this.classDropdownOpen = false;
        this.jobCategoryDropdownOpen = !this.jobCategoryDropdownOpen;
    }

    handleJobCategoryOptionSelect(event) {
        event.stopPropagation();
        const value = event.currentTarget.dataset.value;
        this.header = {
            ...this.header,
            jobCategory: value || null
        };
        this.jobCategoryDropdownOpen = false;
    }

    toggleClassDropdown(event) {
        event.stopPropagation();
        if (this.saving) {
            return;
        }
        this.termsDropdownOpen = false;
        this.jobCategoryDropdownOpen = false;
        this.classDropdownOpen = !this.classDropdownOpen;
    }

    handleClassOptionSelect(event) {
        event.stopPropagation();
        const value = event.currentTarget.dataset.value;
        this.header = {
            ...this.header,
            invoiceClass: value || null
        };
        this.classDropdownOpen = false;
    }

    handleDocumentClick(event) {
        const path = event.composedPath ? event.composedPath() : [];

        if (this.termsDropdownOpen) {
            const termsSelect = this.template.querySelector('.terms-field-select');
            if (!termsSelect || (!path.includes(termsSelect) && !termsSelect.contains(event.target))) {
                this.termsDropdownOpen = false;
            }
        }

        if (this.jobCategoryDropdownOpen) {
            const jobCategorySelect = this.template.querySelector('.job-category-select');
            if (!jobCategorySelect || (!path.includes(jobCategorySelect) && !jobCategorySelect.contains(event.target))) {
                this.jobCategoryDropdownOpen = false;
            }
        }

        if (this.classDropdownOpen) {
            const classSelect = this.template.querySelector('.class-select');
            if (!classSelect || (!path.includes(classSelect) && !classSelect.contains(event.target))) {
                this.classDropdownOpen = false;
            }
        }

        if (this.showProductFinder) {
            const productFinder = this.template.querySelector('.product-finder');
            if (productFinder && path.includes(productFinder)) {
                return;
            }
            if (!productFinder || (!path.includes(productFinder) && !productFinder.contains(event.target))) {
                this.closeProductFinder();
            }
        }
    }

    handleDocumentPointerDown(event) {
        if (!this.showProductFinder) {
            return;
        }
        const path = event.composedPath ? event.composedPath() : [];
        const productFinder = this.template.querySelector('.product-finder');
        if (!productFinder || (!path.includes(productFinder) && !productFinder.contains(event.target))) {
            this.closeProductFinder();
        }
    }

    handleProductFinderClick(event) {
        event.stopPropagation();
    }

    handleOverlayScrollClose() {
        this.termsDropdownOpen = false;
        this.jobCategoryDropdownOpen = false;
        this.classDropdownOpen = false;
        this.template
            .querySelectorAll('lightning-input.invoice-date-input')
            .forEach((dateInput) => dateInput.blur());
    }

    handleContactChange(event) {
        const recordId = event.detail.recordId || null;
        this.header = {
            ...this.header,
            contactId: recordId
        };
        if (recordId) {
            this.contactPickerKey = `contact-picker-${recordId}`;
        }
    }

    handleSalesPersonChange(event) {
        const recordId = event.detail.recordId || null;
        this.header = {
            ...this.header,
            salesPersonId: recordId
        };
    }

    handleOpenNewContactModal() {
        if (!this.workspace?.accountId) {
            this.showToast(
                'Contact unavailable',
                'A customer account is required before you can add a contact.',
                'error'
            );
            return;
        }
        this.newContactFormKey = `new-contact-form-${Date.now()}`;
        this.showNewContactModal = true;
    }

    handleCloseNewContactModal() {
        if (this.creatingContact) {
            return;
        }
        this.showNewContactModal = false;
    }

    handleContactFormSubmit() {
        this.creatingContact = true;
    }

    handleContactCreated(event) {
        const newContactId = event.detail.id;
        this.creatingContact = false;
        this.showNewContactModal = false;

        this.header = {
            ...this.header,
            contactId: newContactId
        };
        this.contactPickerKey = `contact-picker-${newContactId}-${Date.now()}`;

        this.showToast(
            'Contact created',
            'The new contact was saved and selected for this invoice.',
            'success'
        );
    }

    handleContactCreateError(event) {
        this.creatingContact = false;
        this.showToast(
            'Unable to create contact',
            this.extractFormError(event),
            'error'
        );
    }

    handleLineChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        let value;
        if (field === 'includeInInvoice') {
            value = event.detail.checked;
        } else if (field === 'quantity' || field === 'unitPrice') {
            value = Number(event.detail.value);
        } else {
            value = event.detail.value;
        }

        this.lines = this.lines.map(line =>
            line.key === key
                ? this.normalizeLine({ ...line, [field]: value })
                : line
        );
    }

    handleRemoveLine(event) {
        const key = event.currentTarget.dataset.key;
        this.lines = this.lines.map(line =>
            line.key === key ? { ...line, isDeleted: true } : line
        );
        this.refreshSearchProductAvailability();
    }

    // Product search (aligned with Opportunity Quote Builder)
    handleShowProducts(event) {
        event?.stopPropagation();
        if (this.showProductFinder) {
            return;
        }
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
        this.closeProductSearchResults();
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
                if (requestId !== this._activeProductSearchRequest) {
                    return;
                }
                this.productSearchResults = (rows || []).map((product) =>
                    this.mapSearchProductResult({
                        ...product,
                        id: product.pricebookEntryId,
                        productCode: product.productCode || '',
                        description: product.description || ''
                    })
                );
                this.showProductSearchResults = this.productSearchResults.length > 0;
                this.updateAddSelectedButtonState();
            })
            .catch((error) => {
                if (requestId !== this._activeProductSearchRequest) {
                    return;
                }
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
        const targetProduct = this.productSearchResults.find((product) => product.id === pbeId);

        if (targetProduct) {
            this.setPendingSearchSelection(targetProduct, checked);
        }

        this.productSearchResults = this.productSearchResults.map((product) => ({
            ...product,
            isSelected: product.id === pbeId ? checked : product.isSelected
        }));
        this.updateAddSelectedButtonState();
    }

    handleCancelProductSearchResults(event) {
        event?.stopPropagation();
        this.showProductSearchResults = false;
    }

    closeProductSearchResults() {
        this.showProductSearchResults = false;
        this.updateAddSelectedButtonState();
    }

    handleAddSearchSelectedProducts() {
        const pendingSelections = this.getPendingSearchSelections();

        if (!pendingSelections.length) {
            return;
        }

        const newLines = pendingSelections.map((product) =>
            this.normalizeLine({
                key: `manual-${Date.now()}-${Math.random()}`,
                productId: product.productId,
                productName: product.productName,
                productCode: product.productCode,
                description: product.description,
                quantity: 1,
                unitPrice: product.unitPrice,
                cost: product.cost,
                taxable: product.taxable,
                taxAmount: 0,
                includeInInvoice: true,
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

    getSearchSelectionKey(product) {
        return product?.productId || null;
    }

    isPendingSearchSelection(productId) {
        return !!productId && this._pendingSearchSelections.has(productId);
    }

    setPendingSearchSelection(product, selected) {
        const key = this.getSearchSelectionKey(product);
        if (!key) {
            return;
        }
        if (selected) {
            this._pendingSearchSelections.set(key, {
                id: product.id,
                pricebookEntryId: product.pricebookEntryId || product.id,
                productId: product.productId,
                productName: product.productName,
                productCode: product.productCode || '',
                description: product.description || '',
                unitPrice: product.unitPrice,
                cost: product.cost,
                taxable: product.taxable
            });
            return;
        }
        this._pendingSearchSelections.delete(key);
    }

    getPendingSearchSelections() {
        return Array.from(this._pendingSearchSelections.values());
    }

    prunePendingSearchSelections() {
        // No-op to allow duplicate selections
    }

    isProductAlreadyAdded(productId) {
        if (!productId) {
            return false;
        }
        return this.lines.some((line) => !line.isDeleted && line.productId === productId);
    }

    mapSearchProductResult(product, selectionState = {}) {
        const isAlreadyAdded = this.isProductAlreadyAdded(product.productId);
        const isPendingSelected = this.isPendingSearchSelection(product.productId);
        const isSelected = selectionState.isSelected ?? isPendingSelected;
        return {
            ...product,
            isSelected,
            isAlreadyAdded,
            isCheckboxDisabled: this.saving,
            rowClass: 'product-search-result',
            formattedCost: this.formatCurrency(product.cost),
            formattedListPrice: this.formatCurrency(product.unitPrice),
            formattedSalesPrice: this.formatCurrency(product.unitPrice),
            productDescription: product.description || ''
        };
    }

    refreshSearchProductAvailability() {
        if (!this.productSearchResults.length) {
            return;
        }
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

    // ====================== SAVE & VALIDATION ======================
    async handleSave() {
        if (this.saving) {
            return;
        }
        const validationMessage = this.validateBeforeSave();
        if (validationMessage) {
            this.showToast('Review invoice', validationMessage, 'error');
            return;
        }

        this.saving = true;
        try {
            const request = {
                orderId: this.workspace?.orderId || null,
                accountId: this.workspace.accountId,
                contactId: this.header.contactId,
                ownerId: this.header.salesPersonId,
                status: this.header.status,
                classValue: this.header.invoiceClass || null,
                invoiceClass: this.header.invoiceClass || null,
                transactionDate: this.header.transactionDate,
                dueDate: this.header.dueDate,
                terms: this.header.terms,
                jobCategory: this.header.jobCategory,
                poNumber: this.header.poNumber,
                jobDescription: this.header.jobDescription,
                jobDetail: this.header.jobDetail,
                engineerCompletionNotes: this.header.engineerCompletionNotes,
                billingStreet: this.header.billingStreet,
                billingCity: this.header.billingCity,
                billingState: this.header.billingState,
                billingPostalCode: this.header.billingPostalCode,
                syncToQuickBooks: this.header.syncToQuickBooks,
                sendToQuickBooks: this.header.sendToQuickBooks,
                quickBooksInvoiceId: this.header.quickBooksInvoiceId,
                lines: this.lines.filter(line => !line.isDeleted).map(line => ({
                    productId: line.productId,
                    description: line.description,
                    quantity: line.quantity,
                    unitPrice: line.unitPrice,
                    includeInInvoice: line.includeInInvoice !== false,
                    isDeleted: line.isDeleted
                }))
            };

            const result = await createDraftInvoice({ request });
            const invoiceId = result?.invoiceId;

            this.showToast('Invoice created', 'Draft invoice created successfully.', 'success');

            if (invoiceId) {
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: invoiceId,
                        objectApiName: 'fax__Invoice__c',
                        actionName: 'view'
                    }
                });
            }

            // Close the Screen Action after navigation is queued (closing first cancels navigation).
            setTimeout(() => {
                this.dispatchEvent(new CloseActionScreenEvent());
            }, 0);
        } catch (error) {
            this.showToast('Unable to create invoice', this.extractErrorMessage(error), 'error');
        } finally {
            this.saving = false;
        }
    }

    validateBeforeSave() {
        if (!this.workspace?.accountId) return 'Customer is required.';
        if (!this.header?.jobCategory) return 'Job Category is required.';
        if (!this.hasLines) return 'At least one invoice line is required.';

        for (const line of this.activeLines) {
            if (!line.productId) return 'Each invoice line must have a product.';
            if (!line.quantity || Number(line.quantity) <= 0) return 'Quantity must be greater than zero.';
            if (line.unitPrice == null || Number(line.unitPrice) < 0) return 'Sales price cannot be negative.';
        }
        return null;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ====================== UTILITY METHODS ======================
    normalizeLine(line) {
        const quantity = Number(line.quantity || 0);
        const unitPrice = Number(line.unitPrice || 0);

        return {
            ...line,
            quantity,
            unitPrice,
            taxAmount: Number(line.taxAmount || 0),
            total: Number((quantity * unitPrice).toFixed(2)),
            includeInInvoice: line.includeInInvoice !== false,
            isDeleted: line.isDeleted === true
        };
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: 'USD'
        }).format(Number(value || 0));
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

    extractFormError(event) {
        const outputErrors = event.detail?.output?.errors;
        if (outputErrors?.length) {
            return outputErrors.map((entry) => entry.message).join(', ');
        }
        if (event.detail?.message) {
            return event.detail.message;
        }
        return 'Please review the contact details and try again.';
    }
}