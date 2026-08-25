import { LightningElement, api, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';

import getSourceContext from '@salesforce/apex/OpportunityQuoteBuilderController.getSourceContext';
import getStandardActivePricebookId from '@salesforce/apex/OpportunityQuoteBuilderController.getStandardActivePricebookId';
import searchAccounts from '@salesforce/apex/OpportunityQuoteBuilderController.searchAccounts';
import getContacts from '@salesforce/apex/OpportunityQuoteBuilderController.getContacts';
import createContact from '@salesforce/apex/OpportunityQuoteBuilderController.createContact';
import getOpportunities from '@salesforce/apex/OpportunityQuoteBuilderController.getOpportunities';
import searchPricebookEntries from '@salesforce/apex/OpportunityQuoteBuilderController.searchPricebookEntries';
import createOpportunityQuoteAndLines from '@salesforce/apex/OpportunityQuoteBuilderController.createOpportunityQuoteAndLines';

const NEW_OPPORTUNITY_VALUE = '__new__';
const NO_CONTACT_VALUE = '';

export default class OpportunityQuoteBuilder extends NavigationMixin(LightningElement) {
    /** Set automatically when used as a Lightning record action or record page component. */
    _recordId;
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.initializeOnce();
        }
    }
    /** Supports URL/list-view launches such as /lightning/cmp/c__opportunityQuoteBuilder?c__recordIds=... */
    @api recordIds;
    @api sourceObjectApiName;

    @track loading = false;
    @track saving = false;
    @track context;
    @track standardPricebookId;

    @track accountId;
    @track accountName = '';
    @track accountSearchTerm = '';
    @track accountSearchResults = [];
    @track contactId = NO_CONTACT_VALUE;
    @track contactEmail = '';
    @track contactOptions = [];
    @track showCreateContactForm = false;
    @track newContactName = '';
    @track newContactEmail = '';
    @track newContactPhone = '';
    @track creatingContact = false;
    @track opportunityOptions = [];
    @track selectedOpportunityId;
    @track selectedOpportunityPricebookId;

    @track opportunityName = '';
    @track quoteName = '';
    @track quoteDescription = '';
    @track expirationDate;

    @track lines = [];
    @track productSearchTerm = '';
    @track productSearchResults = [];
    @track showProductSearchResults = false;
    @track disableAddSearchProducts = true;
    @track addSearchSelectedLabel = 'Add Selected';

    activeProductSearchRowId;
    inlineProductSearchTimer;
    productSearchTimer;
    accountSearchTimer;
    pageReference;
    hasInitialized = false;
    documentClickHandler;

    _activeProductSearchRequest = 0;
    _lastProductSearchTerm = null;
    _pendingSearchSelections = new Map();

    @wire(CurrentPageReference)
    wiredPageReference(pageReference) {
        this.pageReference = pageReference;
        this.initializeOnce();
    }

    connectedCallback() {
        this.documentClickHandler = this.documentClickHandler || this.handleDocumentClick.bind(this);
        document.addEventListener('click', this.documentClickHandler);
        if (this.recordId || this.recordIds) {
            this.initializeOnce();
        }
    }

    disconnectedCallback() {
        if (this.documentClickHandler) {
            document.removeEventListener('click', this.documentClickHandler);
        }
        clearTimeout(this.productSearchTimer);
        clearTimeout(this.inlineProductSearchTimer);
        clearTimeout(this.accountSearchTimer);
    }

    handleDocumentClick(event) {
        const path = event.composedPath ? event.composedPath() : [];
        const productFinder = this.template.querySelector('.product-finder');
        if (productFinder && path.includes(productFinder)) {
            return;
        }
        this.closeProductSearchResults();
    }

    handleComponentClick() {
        this.closeProductSearchResults();
    }

    handleProductFinderClick(event) {
        event.stopPropagation();
    }

    initializeOnce() {
        if (this.hasInitialized) {
            return;
        }
        this.hasInitialized = true;
        this.loadContext();
    }

    resetFormState() {
        this.saving = false;
        this.context = undefined;
        this.accountId = null;
        this.accountName = '';
        this.accountSearchTerm = '';
        this.accountSearchResults = [];
        this.contactId = NO_CONTACT_VALUE;
        this.contactEmail = '';
        this.contactOptions = [];
        this.showCreateContactForm = false;
        this.newContactName = '';
        this.newContactEmail = '';
        this.newContactPhone = '';
        this.creatingContact = false;
        this.opportunityOptions = [];
        this.selectedOpportunityId = null;
        this.selectedOpportunityPricebookId = null;
        this.opportunityName = '';
        this.quoteName = '';
        this.quoteDescription = '';
        this.expirationDate = undefined;
        this.lines = [];
        this.productSearchTerm = '';
        this.productSearchResults = [];
        this.showProductSearchResults = false;
        this.disableAddSearchProducts = true;
        this.addSearchSelectedLabel = 'Add Selected';
        this.activeProductSearchRowId = undefined;
        this._activeProductSearchRequest++;
        this._lastProductSearchTerm = null;
        this.clearPendingSearchSelections();
    }

    async loadContext() {
        this.loading = false;
        try {
            const sourceRecordId = this.sourceRecordId || null;
            const [standardPricebookId, ctx] = await Promise.all([
                getStandardActivePricebookId(),
                getSourceContext({ sourceRecordId })
            ]);
            this.standardPricebookId = standardPricebookId;
            const pbId = (ctx && ctx.pricebookId) || this.standardPricebookId;
            this.context = { ...ctx, pricebookId: pbId };
            this.applySourceContext(this.context);
            this.expirationDate = this.defaultExpiration();
            this.loading = false;
            if (this.accountId) {
                this.loadAccountRelatedOptions();
            }
        } catch (e) {
            this.toastError(e);
            this.context = { pricebookId: this.standardPricebookId };
        } finally {
            this.loading = false;
        }
    }

    applySourceContext(ctx) {
        if (!ctx) {
            return;
        }
        this.accountId = ctx.accountId || null;
        this.accountName = ctx.accountName || '';
        this.accountSearchTerm = this.accountName;
        this.contactId = ctx.contactId || NO_CONTACT_VALUE;
        this.contactEmail = '';
        this.selectedOpportunityId = ctx.useExistingOpportunity ? ctx.existingOpportunityId : null;
        this.selectedOpportunityPricebookId = ctx.useExistingOpportunity ? ctx.pricebookId : null;
        this.opportunityName =
            (ctx.suggestedOpportunityName && ctx.suggestedOpportunityName.trim()) ||
            this.buildDefaultOpportunityName();
        this.quoteName =
            (ctx.suggestedQuoteName && ctx.suggestedQuoteName.trim()) ||
            this.buildDefaultQuoteName();
    }

    get sourceRecordId() {
        if (this.recordId) {
            return this.sanitizeRecordId(this.recordId);
        }
        const fromApi = this.firstRecordId(this.recordIds);
        if (fromApi) {
            return fromApi;
        }
        const state = (this.pageReference && this.pageReference.state) || {};
        return (
            this.firstRecordId(state.c__recordIds) ||
            this.firstRecordId(state.recordIds) ||
            this.sanitizeRecordId(state.c__recordId) ||
            this.sanitizeRecordId(state.recordId) ||
            null
        );
    }

    firstRecordId(value) {
        const ids = this.normalizeRecordIds(value);
        return ids.length ? ids[0] : null;
    }

    sanitizeRecordId(value) {
        if (value == null || value === '') {
            return null;
        }
        const id = String(value).trim();
        return this.isValidSalesforceId(id) ? id : null;
    }

    isValidSalesforceId(value) {
        return /^[a-zA-Z0-9]{15}$|^[a-zA-Z0-9]{18}$/.test(value);
    }

    normalizeRecordIds(value) {
        if (!value) {
            return [];
        }
        const raw = Array.isArray(value) ? value.join(',') : String(value);
        return raw
            .replace(/[\[\]"()]/g, '')
            .split(',')
            .map((item) => item.trim())
            .filter((item) => this.isValidSalesforceId(item));
    }

    get effectivePricebookId() {
        return (
            this.selectedOpportunityPricebookId ||
            (this.context && this.context.pricebookId) ||
            this.standardPricebookId
        );
    }

    defaultExpiration() {
        const d = new Date();
        d.setDate(d.getDate() + 30);
        return d.toISOString().slice(0, 10);
    }

    get hasNoLines() {
        return !this.lines || this.lines.length === 0;
    }

    get isAccountDisabled() {
        return !!this.recordId;
    }

    get disableContactPicker() {
        return !this.accountId;
    }

    get disableOpportunityPicker() {
        return !this.accountId;
    }

    get contactValue() {
        return this.contactId || NO_CONTACT_VALUE;
    }

    get contactOptionsWithNone() {
        return [{ label: 'No contact selected', value: NO_CONTACT_VALUE }, ...this.contactOptions];
    }

    get saveButtonLabel() {
        return this.saving ? 'Saving...' : 'Save';
    }

    get disableCreateContact() {
        return !this.accountId || this.creatingContact;
    }

    get createContactButtonLabel() {
        return this.showCreateContactForm ? 'Hide New Contact' : 'Create Contact';
    }

    get opportunityValue() {
        return this.selectedOpportunityId || NEW_OPPORTUNITY_VALUE;
    }

    get opportunityOptionsWithNew() {
        return [
            { label: 'Create new Opportunity', value: NEW_OPPORTUNITY_VALUE },
            ...this.opportunityOptions
        ];
    }

    get hasSelectedOpportunity() {
        return !!this.selectedOpportunityId;
    }

    get needsOpportunityName() {
        return !this.hasSelectedOpportunity;
    }

    handleAccountInput(e) {
        this.accountSearchTerm = e.target.value;
        this.accountName = e.target.value;
        this.accountId = null;
        this.contactId = NO_CONTACT_VALUE;
        this.contactEmail = '';
        this.contactOptions = [];
        this.resetCreateContactForm();
        this.opportunityOptions = [];
        this.selectedOpportunityId = null;
        this.selectedOpportunityPricebookId = null;
        clearTimeout(this.accountSearchTimer);
        this.accountSearchTimer = setTimeout(() => this.runAccountSearch(), 300);
    }

    async runAccountSearch() {
        try {
            const rows = await searchAccounts({ keyword: this.accountSearchTerm });
            this.accountSearchResults = this.uniqueAccountResults(rows);
        } catch (e) {
            this.accountSearchResults = [];
            this.toastError(e);
        }
    }

    uniqueAccountResults(rows) {
        const seen = new Set();
        return (rows || []).filter((account) => {
            const key = String(account.label || account.accountName || '').trim().toLowerCase();
            if (!key || seen.has(key)) {
                return false;
            }
            seen.add(key);
            return true;
        });
    }

    async handleSelectAccount(event) {
        const accountId = event.currentTarget.dataset.id;
        const selected = this.accountSearchResults.find((account) => account.accountId === accountId);
        if (!selected) {
            return;
        }
        const shouldDefaultQuoteName = !this.quoteName || !String(this.quoteName).trim();
        this.accountId = selected.accountId;
        this.accountName = selected.accountName;
        this.accountSearchTerm = selected.accountName;
        this.accountSearchResults = [];
        this.contactId = NO_CONTACT_VALUE;
        this.contactEmail = '';
        this.resetCreateContactForm();
        this.selectedOpportunityId = null;
        this.selectedOpportunityPricebookId = null;
        this.opportunityName = this.buildDefaultOpportunityName();
        if (shouldDefaultQuoteName) {
            this.quoteName = this.buildDefaultQuoteName();
        }
        await this.loadAccountRelatedOptions();
    }

    async loadAccountRelatedOptions() {
        await Promise.all([this.loadContacts(), this.loadOpportunities()]);
    }

    async loadContacts() {
        if (!this.accountId) {
            this.contactOptions = [];
            return;
        }
        try {
            const rows = await getContacts({ accountId: this.accountId });
            this.contactOptions = (rows || []).map((contact) => ({
                label: contact.label,
                value: contact.contactId,
                email: contact.email || ''
            }));
            if (this.contactOptions.length === 1 && !this.contactId) {
                this.contactId = this.contactOptions[0].value;
                this.contactEmail = this.contactOptions[0].email || '';
            } else if (this.contactId) {
                this.syncContactEmail();
            }
        } catch (e) {
            this.contactOptions = [];
            this.toastError(e);
        }
    }

    async loadOpportunities() {
        if (!this.accountId) {
            this.opportunityOptions = [];
            return;
        }
        try {
            const rows = await getOpportunities({ accountId: this.accountId });
            this.opportunityOptions = (rows || []).map((opp) => ({
                label: opp.label,
                value: opp.opportunityId,
                name: opp.name,
                pricebookId: opp.pricebookId
            }));
            if (this.selectedOpportunityId) {
                const selected = this.opportunityOptions.find((opp) => opp.value === this.selectedOpportunityId);
                if (selected) {
                    this.selectedOpportunityPricebookId = selected.pricebookId || null;
                }
            }
        } catch (e) {
            this.opportunityOptions = [];
            this.toastError(e);
        }
    }

    handleContactChange(e) {
        this.contactId = e.detail.value || NO_CONTACT_VALUE;
        this.syncContactEmail();
    }

    handleContactEmailChange(e) {
        this.contactEmail = e.target.value;
    }

    handleToggleCreateContact() {
        if (!this.accountId) {
            this.showToast('Error', 'Choose an Account before creating a Contact.', 'error');
            return;
        }
        this.showCreateContactForm = !this.showCreateContactForm;
    }

    handleNewContactNameChange(e) {
        this.newContactName = e.target.value;
    }

    handleNewContactEmailChange(e) {
        this.newContactEmail = e.target.value;
    }

    handleNewContactPhoneChange(e) {
        this.newContactPhone = e.target.value;
    }

    handleCancelCreateContact() {
        this.resetCreateContactForm();
    }

    async handleCreateContact() {
        if (!this.accountId) {
            this.showToast('Error', 'Choose an Account before creating a Contact.', 'error');
            return;
        }
        if (!this.newContactName || !String(this.newContactName).trim()) {
            this.showToast('Error', 'Enter a Contact Name.', 'error');
            return;
        }
        this.creatingContact = true;
        try {
            const contact = await createContact({
                accountId: this.accountId,
                contactName: String(this.newContactName).trim(),
                email: this.newContactEmail || '',
                phone: this.newContactPhone || ''
            });
            const option = {
                label: contact.label,
                value: contact.contactId,
                email: contact.email || ''
            };
            this.contactOptions = [option, ...this.contactOptions];
            this.contactId = option.value;
            this.contactEmail = option.email;
            this.resetCreateContactForm();
            this.showToast('Success', 'Contact was created and selected.', 'success');
        } catch (e) {
            this.toastError(e);
        } finally {
            this.creatingContact = false;
        }
    }

    resetCreateContactForm() {
        this.showCreateContactForm = false;
        this.newContactName = '';
        this.newContactEmail = '';
        this.newContactPhone = '';
    }

    syncContactEmail() {
        const selected = this.contactOptions.find((contact) => contact.value === this.contactId);
        this.contactEmail = selected ? selected.email || '' : '';
    }

    handleOpportunityChange(e) {
        const value = e.detail.value;
        if (!value || value === NEW_OPPORTUNITY_VALUE) {
            this.selectedOpportunityId = null;
            this.selectedOpportunityPricebookId = null;
            this.opportunityName = this.buildDefaultOpportunityName();
            return;
        }
        const selected = this.opportunityOptions.find((opp) => opp.value === value);
        this.selectedOpportunityId = value;
        this.selectedOpportunityPricebookId = selected ? selected.pricebookId : null;
        if (selected && selected.name) {
            this.opportunityName = selected.name;
        }
    }

    handleOpportunityNameChange(e) {
        this.opportunityName = e.target.value;
    }

    handleQuoteNameChange(e) {
        this.quoteName = e.target.value;
    }

    handleExpirationChange(e) {
        this.expirationDate = e.target.value;
    }

    handleDescriptionChange(e) {
        this.quoteDescription = e.target.value;
    }

    buildDefaultOpportunityName() {
        const closeDate = this.expirationDate || this.defaultExpiration();
        return this.accountName ? `${this.accountName} - ${this.formatDateForName(closeDate)}` : '';
    }

    buildDefaultQuoteName() {
        return this.accountName ? `${this.accountName} Quote` : '';
    }

    formatDateForName(value) {
        if (!value) {
            return '';
        }
        const parts = String(value).split('-');
        if (parts.length !== 3) {
            return value;
        }
        return `${parts[1]}/${parts[2]}/${parts[0]}`;
    }

    assertCanPickProduct() {
        if (!this.effectivePricebookId) {
            this.showToast(
                'Error',
                'No active Standard Price Book was found. Activate the Standard Price Book in Setup, or choose an Opportunity with a price book.',
                'error'
            );
            return false;
        }
        if (!this.accountId) {
            this.showToast('Error', 'Choose an Account before selecting products.', 'error');
            return false;
        }
        return true;
    }

    blankLine() {
        return {
            id: `${Date.now()}-${Math.random()}`,
            pricebookEntryId: null,
            productName: '',
            productCode: '',
            productSearchTerm: '',
            productResults: [],
            showProductResults: false,
            disableAddSelectedProducts: true,
            addSelectedLabel: 'Add Selected',
            cost: null,
            description: '',
            includeInQuote: true,
            quantity: 1,
            unitPrice: 0
        };
    }

    clearPendingSearchSelections() {
        this._pendingSearchSelections.clear();
    }

    getSearchSelectionKey(product) {
        return product?.id || null;
    }

    isPendingSearchSelection(pbeId) {
        return !!pbeId && this._pendingSearchSelections.has(pbeId);
    }

    setPendingSearchSelection(product, selected) {
        const key = this.getSearchSelectionKey(product);
        if (!key) {
            return;
        }
        if (selected) {
            this._pendingSearchSelections.set(key, {
                id: product.id,
                productId: product.productId,
                productName: product.productName,
                productCode: product.productCode || '',
                description: product.description || '',
                listPrice: product.listPrice,
                cost: product.cost
            });
            return;
        }
        this._pendingSearchSelections.delete(key);
    }

    getPendingSearchSelections() {
        return Array.from(this._pendingSearchSelections.values());
    }

    isProductAlreadyAdded(pricebookEntryId) {
        if (!pricebookEntryId) {
            return false;
        }
        return this.lines.some((line) => line.pricebookEntryId === pricebookEntryId);
    }

    mapSearchProductResult(product, selectionState = {}) {
        const isAlreadyAdded = this.isProductAlreadyAdded(product.id);
        const isPendingSelected = this.isPendingSearchSelection(product.id);
        const isSelected = selectionState.isSelected ?? isPendingSelected;
        return {
            ...product,
            isSelected,
            isAlreadyAdded,
            isCheckboxDisabled: this.saving,
            rowClass: isAlreadyAdded
                ? 'product-search-result product-search-result-added'
                : 'product-search-result',
            formattedCost: this.formatCurrency(product.cost),
            formattedListPrice: this.formatCurrency(product.listPrice),
            description: product.description || ''
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

    handleAddBlankLine() {
        if (!this.assertCanPickProduct()) {
            return;
        }
        this.productSearchTerm = '';
        this.runProductSearch('');
    }

    handleProductSearchFocus() {
        if (!this.assertCanPickProduct()) {
            return;
        }
        this.runProductSearch(this.productSearchTerm || '');
    }

    handleProductSearch(event) {
        this.productSearchTerm = event.target.value;
        clearTimeout(this.productSearchTimer);
        this.productSearchTimer = setTimeout(() => this.runProductSearch(this.productSearchTerm), 300);
    }

    runProductSearch(searchTerm) {
        if (!this.assertCanPickProduct()) {
            return;
        }
        const normalizedTerm = (searchTerm || '').trim();
        if (normalizedTerm === this._lastProductSearchTerm && this.productSearchResults.length > 0) {
            this.refreshSearchProductAvailability();
            this.showProductSearchResults = true;
            return;
        }

        this._lastProductSearchTerm = normalizedTerm;
        const requestId = ++this._activeProductSearchRequest;

        searchPricebookEntries({
            pricebookId: this.effectivePricebookId,
            searchTerm: normalizedTerm
        })
            .then((rows) => {
                if (requestId !== this._activeProductSearchRequest) {
                    return;
                }
                this.productSearchResults = (rows || []).map((product) =>
                    this.mapSearchProductResult(product)
                );
                this.showProductSearchResults = this.productSearchResults.length > 0;
                this.updateAddSelectedButtonState();
            })
            .catch((e) => {
                if (requestId !== this._activeProductSearchRequest) {
                    return;
                }
                this.showProductSearchResults = false;
                this.productSearchResults = [];
                this.toastError(e);
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
        this.closeProductSearchResults();
    }

    closeProductSearchResults() {
        this.showProductSearchResults = false;
        this.productSearchResults = [];
        this._activeProductSearchRequest++;
        this._lastProductSearchTerm = null;
        this.clearPendingSearchSelections();
        this.updateAddSelectedButtonState();
    }

    handleAddSearchSelectedProducts() {
        const pendingSelections = this.getPendingSearchSelections();
        if (!pendingSelections.length) {
            return;
        }
        const selectedLines = pendingSelections.map((product) => this.buildLineFromProduct(this.blankLine(), product));
        this.lines = [...this.lines, ...selectedLines];
        this.clearPendingSearchSelections();
        this.closeProductSearchResults();
    }

    handleInlineProductFocus(event) {
        const rowId = event.currentTarget.dataset.rowId;
        if (!rowId || !this.assertCanPickProduct()) {
            return;
        }
        this.activeProductSearchRowId = rowId;
        const line = this.lines.find((row) => row.id === rowId);
        this.runInlineProductSearch(rowId, line ? line.productSearchTerm : '');
    }

    handleInlineProductSearch(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const searchTerm = event.target.value;
        this.activeProductSearchRowId = rowId;
        this.lines = this.lines.map((line) =>
            line.id === rowId
                ? {
                      ...line,
                      productSearchTerm: searchTerm,
                      pricebookEntryId: null,
                      productName: '',
                      productCode: '',
                      cost: null,
                      unitPrice: 0,
                      showProductResults: false
                  }
                : { ...line, showProductResults: false }
        );
        clearTimeout(this.inlineProductSearchTimer);
        this.inlineProductSearchTimer = setTimeout(() => this.runInlineProductSearch(rowId, searchTerm), 300);
    }

    runInlineProductSearch(rowId, searchTerm) {
        if (!this.assertCanPickProduct()) {
            return;
        }
        searchPricebookEntries({
            pricebookId: this.effectivePricebookId,
            searchTerm
        })
            .then((rows) => {
                const productResults = (rows || [])
                    .map((product) => ({
                        ...product,
                        productCode: product.productCode || '',
                        description: product.description || '',
                        isSelected: false,
                        formattedCost: this.formatCurrency(product.cost),
                        formattedListPrice: this.formatCurrency(product.listPrice)
                    }));
                this.lines = this.lines.map((line) =>
                    line.id === rowId
                        ? {
                              ...line,
                              productResults,
                              showProductResults: productResults.length > 0,
                              disableAddSelectedProducts: true,
                              addSelectedLabel: 'Add Selected'
                          }
                        : { ...line, showProductResults: false }
                );
            })
            .catch((e) => this.toastError(e));
    }

    handleProductResultSelection(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const pbeId = event.currentTarget.dataset.pbeId;
        const checked = event.target.checked;
        this.lines = this.lines.map((line) => {
            if (line.id !== rowId) {
                return line;
            }
            const productResults = (line.productResults || []).map((product) => ({
                ...product,
                isSelected: product.id === pbeId ? checked : product.isSelected
            }));
            return {
                ...line,
                productResults,
                disableAddSelectedProducts: !productResults.some((product) => product.isSelected),
                addSelectedLabel: this.buildAddSelectedLabel(productResults)
            };
        });
    }

    buildAddSelectedLabel(productResults) {
        const selectedCount = (productResults || []).filter((product) => product.isSelected).length;
        return selectedCount ? `Add Selected (${selectedCount})` : 'Add Selected';
    }

    handleAddSelectedProducts(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const line = this.lines.find((row) => row.id === rowId);
        const selectedProducts = line && line.productResults
            ? line.productResults.filter((product) => product.isSelected)
            : [];
        if (!selectedProducts.length) {
            return;
        }
        const newLines = [];
        this.lines.forEach((row) => {
            if (row.id !== rowId) {
                newLines.push(row);
                return;
            }
            selectedProducts.forEach((product, index) => {
                newLines.push(this.buildLineFromProduct(index === 0 ? row : this.blankLine(), product));
            });
        });
        this.lines = newLines;
    }

    buildLineFromProduct(baseLine, product) {
        const listPrice = product.listPrice != null ? Number(product.listPrice) : 0;
        const displayName = this.cleanProductDisplayName(product.productName, product.productCode);
        return {
            ...baseLine,
            pricebookEntryId: product.id,
            productName: product.productName,
            productCode: product.productCode || '',
            description: product.description || baseLine.description || '',
            productSearchTerm: displayName,
            cost: product.cost,
            unitPrice: listPrice,
            productResults: [],
            showProductResults: false,
            disableAddSelectedProducts: true,
            addSelectedLabel: 'Add Selected'
        };
    }

    cleanProductDisplayName(productName, productCode) {
        const name = productName || '';
        const code = productCode || '';
        if (!code || !name.startsWith(code)) {
            return name;
        }
        return name
            .replace(new RegExp(`^${this.escapeRegExp(code)}\\s*[-–—:]?\\s*`, 'i'), '')
            .trim() || name;
    }

    escapeRegExp(value) {
        return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }

    formatCurrency(value) {
        if (value === null || value === undefined || value === '') {
            return '$0.00';
        }
        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: 'USD'
        }).format(Number(value));
    }

    handleRemoveLine(event) {
        const rowId = event.currentTarget.dataset.rowId;
        if (!rowId) {
            return;
        }
        this.lines = this.lines.filter((l) => l.id !== rowId);
        this.refreshSearchProductAvailability();
    }

    handleLineFieldChange(event) {
        const rowId = event.currentTarget.dataset.rowId;
        const field = event.currentTarget.dataset.field;
        if (!rowId || !field) {
            return;
        }
        const raw =
            event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        let value = raw;
        if (field === 'quantity' || field === 'unitPrice') {
            value = raw === '' || raw == null ? null : Number(raw);
        } else if (field === 'includeInQuote') {
            value = event.target.checked;
        }
        this.lines = this.lines.map((l) => (l.id === rowId ? { ...l, [field]: value } : l));
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
        if (!this.recordId || (this.pageReference && this.pageReference.type === 'standard__component')) {
            window.history.back();
        }
    }

    handleSave() {
        if (!this.accountId) {
            this.showToast('Error', 'Choose an Account.', 'error');
            return;
        }
        if (!this.contactId || this.contactId === NO_CONTACT_VALUE) {
            this.showToast('Error', 'Choose a Contact.', 'error');
            return;
        }
        if (!this.selectedOpportunityId && (!this.opportunityName || !String(this.opportunityName).trim())) {
            this.showToast('Error', 'Enter an Opportunity Name or choose an existing Opportunity.', 'error');
            return;
        }
        if (!this.quoteName || !String(this.quoteName).trim()) {
            this.showToast('Error', 'Enter a Quote Name.', 'error');
            return;
        }
        const selectedLines = this.lines.filter((line) => line.pricebookEntryId);
        if (!selectedLines.length) {
            this.showToast('Error', 'Add at least one product.', 'error');
            return;
        }
        const invalid = selectedLines.some(
            (l) => !l.pricebookEntryId || l.quantity == null || l.quantity <= 0
        );
        if (invalid) {
            this.showToast(
                'Error',
                'Each product line needs a product and a quantity greater than zero.',
                'error'
            );
            return;
        }

        const payload = selectedLines.map((l) => ({
            pricebookEntryId: l.pricebookEntryId,
            quantity: l.quantity,
            unitPrice: l.unitPrice,
            description: l.description || '',
            includeInQuote: l.includeInQuote !== false
        }));

        this.saving = true;
        createOpportunityQuoteAndLines({
            sourceRecordId: this.sourceRecordId || null,
            accountId: this.accountId,
            contactId: this.contactId || null,
            existingOpportunityId: this.selectedOpportunityId || null,
            opportunityName: this.opportunityName ? String(this.opportunityName).trim() : '',
            quoteName: String(this.quoteName).trim(),
            quoteExpirationDate: this.expirationDate || null,
            description: this.quoteDescription || '',
            lines: payload
        })
            .then((res) => {
                this.showToast('Success', 'Draft quote was created.', 'success');
                this.resetFormState();
                this.dispatchEvent(new CloseActionScreenEvent());
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: res.quoteId,
                        actionName: 'view'
                    }
                });
            })
            .catch((e) => this.toastError(e))
            .finally(() => {
                this.saving = false;
            });
    }

    toastError(error) {
        this.showToast('Error', this.extractErrorMessage(error), 'error');
    }

    extractErrorMessage(error) {
        if (!error) {
            return 'Unexpected error';
        }
        const body = error.body || {};
        if (Array.isArray(body.output?.errors) && body.output.errors.length) {
            return body.output.errors.map((item) => item.message).filter(Boolean).join(' ');
        }
        if (Array.isArray(body.pageErrors) && body.pageErrors.length) {
            return body.pageErrors.map((item) => item.message).filter(Boolean).join(' ');
        }
        if (body.fieldErrors) {
            const fieldMessages = [];
            Object.keys(body.fieldErrors).forEach((fieldName) => {
                const entries = body.fieldErrors[fieldName] || [];
                entries.forEach((entry) => {
                    if (entry && entry.message) {
                        fieldMessages.push(entry.message);
                    }
                });
            });
            if (fieldMessages.length) {
                return fieldMessages.join(' ');
            }
        }
        if (body.message && body.message !== 'An internal server error has occurred') {
            return body.message;
        }
        if (error.message) {
            return error.message;
        }
        return 'Unexpected error';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}