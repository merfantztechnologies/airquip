import { LightningElement, api, track, wire } from 'lwc';
import { loadStyle } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { MessageContext, subscribe, unsubscribe } from 'lightning/messageService';
import INVOICE_LINE_ITEMS_CHANGED from '@salesforce/messageChannel/InvoiceLineItemsChanged__c';
import modal from '@salesforce/resourceUrl/modalPopup';
import getInvoiceLineItems from '@salesforce/apex/InvoiceLineItemEditorController.getInvoiceLineItems';
import getInvoiceSummaryContext from '@salesforce/apex/InvoiceLineItemEditorController.getInvoiceSummaryContext';
import getInvoiceLineItemFieldOptions from '@salesforce/apex/InvoiceLineItemEditorController.getInvoiceLineItemFieldOptions';
import searchActiveProducts from '@salesforce/apex/InvoiceLineItemEditorController.searchActiveProducts';
import saveInvoiceLineItems from '@salesforce/apex/InvoiceLineItemEditorController.saveInvoiceLineItems';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';

const SEARCH_DEBOUNCE_MS = 300;
const MAX_SORT_CRITERIA = 5;
const SORT_MODE_COLUMN = 'column';
const SORT_MODE_MANUAL = 'manual';

const BUILTIN_SORT_FIELD_OPTIONS = [
    { label: 'Product', value: 'product' },
    { label: 'Cost', value: 'cost' },
    { label: 'Sales Price', value: 'salesPrice' },
    { label: 'Quantity', value: 'quantity' },
    { label: 'Subtotal', value: 'subtotal' },
    { label: 'Total Price', value: 'totalPrice' },
    { label: 'Line Item Description', value: 'lineItemDescription' },
    { label: 'Include In Invoice', value: 'includeInInvoice' }
];

function buildSortCriterionId() {
    return `sort-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
}

function createDefaultSortCriterion(field = 'product', direction = 'asc') {
    return {
        id: buildSortCriterionId(),
        field,
        direction
    };
}

function cloneSortCriteria(criteria) {
    return (criteria || []).map((criterion) => ({
        id: criterion.id || buildSortCriterionId(),
        field: criterion.field || '',
        direction: criterion.direction === 'desc' ? 'desc' : 'asc'
    }));
}

const DEFAULT_TABLE_COLUMNS = [
    { key: 'product', label: 'Product', headerClass: 'line-product-cell' },
    { key: 'cost', label: 'Cost', headerClass: '' },
    { key: 'salesPrice', label: 'Sales Price', headerClass: '' },
    { key: 'quantity', label: 'Quantity', headerClass: '' },
    { key: 'subtotal', label: 'Subtotal', headerClass: '' },
    { key: 'totalPrice', label: 'Total Price', headerClass: '' },
    { key: 'lineItemDescription', label: 'Line Item Description', headerClass: '' },
    { key: 'includeInInvoice', label: 'Include In Invoice', headerClass: 'checkbox-col' }
];

const BUILTIN_TABLE_COLUMN_KEYS = new Set(DEFAULT_TABLE_COLUMNS.map((column) => column.key));

const DEFAULT_SELECTED_TABLE_COLUMNS = DEFAULT_TABLE_COLUMNS.map((column) => column.key);

const DEFAULT_INVOICE_LINE_TABLE_FIELD_API_NAMES = new Set([
    'cost__c',
    'fax__cost__c',
    'fax__unit_price__c',
    'fax__qty__c',
    'quantity__c',
    'fax__discount__c',
    'fax__total_amount__c',
    'fax__total_amount_excl_tax__c',
    'fax__tax__c',
    'include_in_invoice__c',
    'description__c',
    'taxable__c',
    'fax__product__c',
    'fax__invoice__c'
]);

function normalizeInvoiceLineFieldApiName(apiName) {
    return (apiName || '').trim().toLowerCase();
}

function isDefaultInvoiceLineTableField(apiName) {
    return DEFAULT_INVOICE_LINE_TABLE_FIELD_API_NAMES.has(normalizeInvoiceLineFieldApiName(apiName));
}

function isBuiltinTableColumn(columnKey) {
    return BUILTIN_TABLE_COLUMN_KEYS.has(columnKey);
}

function getInvoiceLineFieldMapValue(fieldValues, fieldApiName) {
    if (!fieldValues || !fieldApiName) {
        return '';
    }
    if (fieldValues[fieldApiName] != null && String(fieldValues[fieldApiName]).length) {
        return String(fieldValues[fieldApiName]);
    }
    const target = normalizeInvoiceLineFieldApiName(fieldApiName);
    for (const key of Object.keys(fieldValues)) {
        if (normalizeInvoiceLineFieldApiName(key) === target) {
            const value = fieldValues[key];
            return value != null && String(value).length ? String(value) : '';
        }
    }
    return '';
}

const INVOICE_LINE_ITEM_OBJECT_API_NAME = 'fax__Invoice_Line_Item__c';

export default class InvoiceLineItemEditor extends LightningElement {
    @api recordId;

    @wire(MessageContext)
    messageContext;

    @track rows = [];
    @track loading = false;
    @track saving = false;
    @track errorMessage = '';
    @track isModalOpen = false;
    @track showProductFinder = false;
    @track productSearchTerm = '';
    @track productSearchResults = [];
    @track showProductSearchResults = false;
    @track disableAddSearchProducts = true;
    @track addSearchSelectedLabel = 'Add Selected';
    @track showCardMenu = false;
    @track showSettingsMenu = false;
    @track showLineFieldSelectorModal = false;
    @track showSortModal = false;
    @track sortCriteria = [createDefaultSortCriterion()];
    @track draftSortCriteria = [];
    @track sortMode = SORT_MODE_COLUMN;
    @track draggedRowKey = null;
    @track invoiceLineFieldOptions = [];
    @track invoiceLineFieldOptionsLoading = false;
    @track selectedTableColumns = [...DEFAULT_SELECTED_TABLE_COLUMNS];
    @track draftSelectedTableColumns = [];
    @track previewLineItems = [];

    deletedLineItemIds = [];
    originalRows = [];
    @track invoiceTaxPercent = 0;
    invoiceLineFieldLabelByApiName = {};
    searchTimersByRowId = {};
    productSearchTimer;
    _ignoreNextFocusSearch = false;
    _pendingFinderSelections = new Map();
    documentClickHandler;
    requestCounter = 0;
    hasLoadedRows = false;
    blurTimer;
    bodyScrollLocked = false;
    savedScrollY = 0;
    originalBodyOverflow = '';
    originalBodyPosition = '';
    originalBodyTop = '';
    originalBodyWidth = '';
    originalHtmlOverflow = '';
    refreshHandlerId;
    lineItemsChangedSubscription;

    connectedCallback() {
        loadStyle(this, modal);
        this.loadRows();
        this.documentClickHandler = this.handleDocumentClick.bind(this);
        document.addEventListener('click', this.documentClickHandler);
        this.handleInvoiceLineItemsChangedEvent = this.handleInvoiceLineItemsChangedEvent.bind(this);
        window.addEventListener('invoiceLineItemsChanged', this.handleInvoiceLineItemsChangedEvent);
        this.refreshHandlerId = registerRefreshHandler(this.template.host, () =>
            this.reloadLineItemsFromServer()
        );
    }

    renderedCallback() {
        if (this.messageContext && !this.lineItemsChangedSubscription) {
            this.lineItemsChangedSubscription = subscribe(
                this.messageContext,
                INVOICE_LINE_ITEMS_CHANGED,
                (message) => this.handleInvoiceLineItemsChanged(message)
            );
        }
    }

    disconnectedCallback() {
        if (this.documentClickHandler) {
            document.removeEventListener('click', this.documentClickHandler);
        }
        if (this.refreshHandlerId) {
            unregisterRefreshHandler(this.refreshHandlerId);
            this.refreshHandlerId = null;
        }
        if (this.lineItemsChangedSubscription) {
            unsubscribe(this.lineItemsChangedSubscription);
            this.lineItemsChangedSubscription = null;
        }
        if (this.handleInvoiceLineItemsChangedEvent) {
            window.removeEventListener('invoiceLineItemsChanged', this.handleInvoiceLineItemsChangedEvent);
        }
        clearTimeout(this.productSearchTimer);
        Object.keys(this.searchTimersByRowId).forEach((rowKey) => this.clearRowTimer(rowKey));
        if (this.blurTimer) clearTimeout(this.blurTimer);
        this.unlockBackgroundScroll();
    }

    // Getters
    get lineItemsCountDisplay() {
        const count = this.getPreviewSourceRows().length;
        return count > 3 ? '3+' : String(count);
    }

    get hasPreviewItems() {
        return this.previewLineItems.length > 0;
    }

    get summaryEligibleRows() {
        return (this.rows || []).filter(
            (row) =>
                row.includeInInvoice !== false &&
                (row.pricebookEntryId || row.productId)
        );
    }

    getTaxableEligibleRows() {
        return this.summaryEligibleRows.filter((row) => row.taxable === true);
    }

    /**
     * Mirrors fax__Invoice__c.Sub_Total__c — sum of fax__Total_Amount_Excl_Tax__c
     * for line items where Include_In_Invoice__c is true.
     */
    calculateInvoiceSubTotal() {
        return Number(
            this.summaryEligibleRows
                .reduce((sum, row) => sum + this.getRowAmountExclTax(row), 0)
                .toFixed(2)
        );
    }

    /**
     * Mirrors fax__Invoice__c.Sub_Total_Tax_Product__c from InvoiceLineItemTriggerHandler —
     * taxable included line totals × invoice tax percent, rounded to 2 decimals
     * (same display rule as InvoicePreview.page tax row).
     */
    calculateInvoiceTaxAmount() {
        const taxPercent = this.toNumber(this.invoiceTaxPercent, 0);
        if (taxPercent === 0) {
            return 0;
        }

        const taxableSubtotal = this.getTaxableEligibleRows().reduce(
            (sum, row) => sum + this.getRowAmountExclTax(row),
            0
        );

        return Number(((taxableSubtotal * taxPercent) / 100).toFixed(2));
    }

    /**
     * Mirrors fax__Invoice__c.Grand_Total__c formula: Sub_Total__c + Sub_Total_Tax_Product__c.
     */
    calculateInvoiceGrandTotal() {
        return Number(
            (this.calculateInvoiceSubTotal() + this.calculateInvoiceTaxAmount()).toFixed(2)
        );
    }

    get lineItemsSubtotal() {
        return this.calculateInvoiceSubTotal();
    }

    get lineItemsTax() {
        return this.calculateInvoiceTaxAmount();
    }

    get lineItemsGrandTotal() {
        return this.calculateInvoiceGrandTotal();
    }

    get formattedLineItemsSubtotal() {
        return this.formatCurrency(this.lineItemsSubtotal);
    }

    get formattedLineItemsTax() {
        return this.formatCurrency(this.lineItemsTax);
    }

    get formattedLineItemsGrandTotal() {
        return this.formatCurrency(this.lineItemsGrandTotal);
    }

    applyInvoiceTaxPercent(nextTaxPercent) {
        this.invoiceTaxPercent = this.toNumber(nextTaxPercent, 0);
    }

    async refreshInvoiceSummaryContext() {
        if (!this.recordId) {
            return;
        }

        try {
            const summaryContext = await getInvoiceSummaryContext({ invoiceId: this.recordId });
            this.applyInvoiceTaxPercent(summaryContext?.taxPercent);
            this.setRows([...this.rows], { skipTaxRefresh: true });
        } catch (error) {
            // Keep existing values when the summary refresh fails.
        }
    }

    async refreshInvoiceTaxPercentIfNeeded() {
        if (this.toNumber(this.invoiceTaxPercent, 0) !== 0) {
            return;
        }
        if (!this.recordId || this.summaryEligibleRows.length === 0) {
            return;
        }

        await this.refreshInvoiceSummaryContext();
    }

    setRows(rows, options = {}) {
        this.rows = this.applyLineTaxAmountsToRows(rows);
        this.syncPreviewLineItems();
        if (!options.skipTaxRefresh) {
            void this.refreshInvoiceTaxPercentIfNeeded();
        }
    }

    async ensureInvoiceTaxPercentLoaded() {
        if (!this.recordId || this.toNumber(this.invoiceTaxPercent, 0) !== 0) {
            return;
        }

        await this.refreshInvoiceSummaryContext();
    }

    applyLineTaxAmountsToRows(rows) {
        return (rows || []).map((row) => ({
            ...row,
            discountAmt: this.getRowDiscountAmount(row),
            amountExclTax: this.getRowAmountExclTax(row),
            subtotal: this.calculateSubtotal(row.quantity, row.salesPrice),
            taxAmount: this.calculateRowTaxAmountForInvoice(row),
            totalPrice: this.calculateRowTotalPriceWithTax(row)
        }));
    }

    getRowDiscountAmount(row) {
        if (row.recalculateDiscountAmt === true || row.discountAmt == null) {
            return this.calculateDiscountAmount(row.quantity, row.salesPrice, row.discount);
        }
        return this.toNumber(row.discountAmt, 0);
    }

    getRowTaxBase(row) {
        const qty = this.toNumber(row.quantity, 0);
        const unitPrice = this.toNumber(row.salesPrice, 0);
        const discountAmt = this.getRowDiscountAmount(row);
        return qty * unitPrice - discountAmt;
    }

    getRowAmountExclTax(row) {
        return Number(this.getRowTaxBase(row).toFixed(2));
    }

    calculateDiscountAmount(quantity, unitPrice, discountPercent) {
        const subtotal = this.calculateSubtotal(quantity, unitPrice);
        const discountPct = this.toNumber(discountPercent, 0);
        if (discountPct === 0) {
            return 0;
        }
        return Number((subtotal * (discountPct / 100)).toFixed(2));
    }

    calculateLineTaxAmount(row) {
        return this.calculateRowTaxAmountForInvoice(row);
    }

    calculateRowTaxAmountForInvoice(row) {
        if (!row || row.includeInInvoice === false || row.taxable !== true) {
            return 0;
        }

        const taxPercent = this.toNumber(this.invoiceTaxPercent, 0);
        if (taxPercent === 0) {
            return 0;
        }

        const taxBase = this.getRowAmountExclTax(row);
        return Number((taxBase * (taxPercent / 100)).toFixed(2));
    }

    calculateRowTotalPriceWithTax(row) {
        if (!row || row.includeInInvoice === false) {
            return 0;
        }

        const amountExclTax = this.getRowAmountExclTax(row);
        return Number((amountExclTax + this.calculateRowTaxAmountForInvoice(row)).toFixed(2));
    }

    getPreviewSourceRows() {
        return this.getRowsInPersistedSortOrder().filter((row) => this.isPreviewableRow(row));
    }

    getRowsInPersistedSortOrder() {
        const rows = [...(this.rows || [])];
        if (!rows.length) {
            return [];
        }

        // Card preview follows saved/manual order (Display_Order / Sort_Order), not column-sort view.
        if (this.sortMode === SORT_MODE_MANUAL) {
            return rows;
        }

        return rows.sort((rowA, rowB) => this.comparePersistedSortOrder(rowA, rowB));
    }

    comparePersistedSortOrder(rowA, rowB) {
        return this.compareNullableSortNumbers(rowA.sortOrder, rowB.sortOrder);
    }

    compareNullableSortNumbers(valueA, valueB) {
        const numberA = this.toNullableNumber(valueA);
        const numberB = this.toNullableNumber(valueB);

        if (numberA == null && numberB == null) {
            return 0;
        }
        if (numberA == null) {
            return 1;
        }
        if (numberB == null) {
            return -1;
        }

        return numberA - numberB;
    }

    isPreviewableRow(row) {
        return !!(row && (row.pricebookEntryId || row.productId));
    }

    syncPreviewLineItems() {
        this.previewLineItems = this.getPreviewSourceRows()
            .slice(0, 3)
            .map((row, index) => {
                const invoiceLineItemId = row.invoiceLineItemId || null;
                return {
                    key: row.key || `preview-${index}`,
                    name: this.formatPreviewLineItemName(row),
                    productDisplay: this.formatPreviewProductName(row),
                    quantityDisplay: row.quantity ?? '0',
                    unitPrice: this.formatCurrency(row.salesPrice),
                    recordPageUrl: this.getInvoiceLineItemRecordPageUrl(invoiceLineItemId)
                };
            });
    }

    formatPreviewLineItemName(row) {
        const name = row.lineItemName || row.productName || row.productSearchTerm || '';
        return name || '—';
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get saveLabel() {
        return this.saving ? 'Saving...' : 'Save';
    }

    get tableColumnHeaders() {
        return this.getVisibleColumnDefinitions();
    }

    get tableColumnPickerOptions() {
        const builtinOptions = DEFAULT_TABLE_COLUMNS.map((column) => ({
            label: column.label,
            value: column.key
        }));
        const fieldOptions = (this.invoiceLineFieldOptions || []).map((field) => ({
            label: field.label,
            value: field.apiName
        }));
        return [...builtinOptions, ...fieldOptions];
    }

    get hasTableColumnPickerOptions() {
        return this.tableColumnPickerOptions.length > 0;
    }

    get sortFieldOptions() {
        const optionalFieldOptions = (this.invoiceLineFieldOptions || []).map((field) => ({
            label: field.label,
            value: field.apiName
        }));
        return [...BUILTIN_SORT_FIELD_OPTIONS, ...optionalFieldOptions];
    }

    get canAddSortCriterion() {
        return this.draftSortCriteria.length < MAX_SORT_CRITERIA;
    }

    get sortColumnLimitLabel() {
        return `${MAX_SORT_CRITERIA} column limit`;
    }

    get sortCriteriaForTemplate() {
        const selectedFields = new Set(
            this.draftSortCriteria.map((criterion) => criterion.field).filter(Boolean)
        );

        return this.draftSortCriteria.map((criterion, index) => {
            const fieldOptions = this.sortFieldOptions.filter(
                (option) => option.value === criterion.field || !selectedFields.has(option.value)
            );

            return {
                id: criterion.id,
                field: criterion.field,
                direction: criterion.direction,
                rowLabel: index === 0 ? 'Sort by' : 'Then by',
                isAscending: criterion.direction !== 'desc',
                isDescending: criterion.direction === 'desc',
                disableMoveUp: this.saving || index === 0,
                disableMoveDown: this.saving || index === this.draftSortCriteria.length - 1,
                hasError: !criterion.field,
                fieldClass: criterion.field
                    ? 'sort-criterion-field'
                    : 'sort-criterion-field sort-criterion-field_error',
                fieldOptions
            };
        });
    }

    get rowsForTemplate() {
        const columnDefinitions = this.getVisibleColumnDefinitions();
        return this.getDisplayRows().map((row) => ({
            ...row,
            rowClass: this.draggedRowKey === row.key
                ? 'invoice-line-row invoice-line-row_dragging'
                : 'invoice-line-row',
            isDraggable: !this.saving,
            productDisplay: this.formatProductDisplay(row),
            subtotalDisplay: this.formatCurrency(row.subtotal),
            totalPriceDisplay: this.formatCurrency(this.getRowAmountExclTax(row)),
            tableCells: this.buildRowTableCells(row, columnDefinitions)
        }));
    }

    formatPreviewProductName(row) {
        const name = row.productName || row.productSearchTerm || '';
        return name || '—';
    }

    formatProductDisplay(row) {
        const name = row.productName || row.productSearchTerm || '';
        return name || '—';
    }

    // Modal Handlers
    async handleOpenModal() {
        this.isModalOpen = true;
        this.lockBackgroundScroll();
        if (this.recordId) {
            await this.loadRows();
        }
    }

    handleToggleCardMenu(event) {
        event.stopPropagation();
        this.showCardMenu = !this.showCardMenu;
    }

    handleCardMenuContainerClick(event) {
        event.stopPropagation();
    }

    handleEditClick(event) {
        event.stopPropagation();
        this.showCardMenu = false;
        this.handleOpenModal();
    }

    handleCloseModal() {
        if (this.saving) return;
        this.isModalOpen = false;
        this.showCardMenu = false;
        this.showSettingsMenu = false;
        this.showSortModal = false;
        this.draftSortCriteria = [];
        this.resetProductFinderState();
        this.unlockBackgroundScroll();
    }

    lockBackgroundScroll() {
        if (this.bodyScrollLocked) {
            return;
        }

        this.savedScrollY = window.scrollY || document.documentElement.scrollTop || 0;
        const body = document.body;

        this.originalBodyOverflow = body.style.overflow;
        this.originalBodyPosition = body.style.position;
        this.originalBodyTop = body.style.top;
        this.originalBodyWidth = body.style.width;
        this.originalHtmlOverflow = document.documentElement.style.overflow;

        body.style.overflow = 'hidden';
        body.style.position = 'fixed';
        body.style.top = `-${this.savedScrollY}px`;
        body.style.width = '100%';
        document.documentElement.style.overflow = 'hidden';

        this.bodyScrollLocked = true;
    }

    unlockBackgroundScroll() {
        if (!this.bodyScrollLocked) {
            return;
        }

        const body = document.body;
        body.style.overflow = this.originalBodyOverflow;
        body.style.position = this.originalBodyPosition;
        body.style.top = this.originalBodyTop;
        body.style.width = this.originalBodyWidth;
        document.documentElement.style.overflow = this.originalHtmlOverflow;

        window.scrollTo(0, this.savedScrollY);
        this.bodyScrollLocked = false;
    }

    // Click Handlers
    handleToolbarClick(event) {
        event.stopPropagation();
    }

    handleDocumentClick(event) {
        const path = event.composedPath ? event.composedPath() : [];

        if (this.showCardMenu) {
            const cardMenu = this.template.querySelector('.card-menu-container');
            if (!cardMenu || !path.includes(cardMenu)) {
                this.showCardMenu = false;
            }
        }

        if (!this.showProductFinder) {
            return;
        }

        const productFinder = this.template.querySelector('.product-finder');
        const lineItemsSection = this.template.querySelector('.line-items-section');

        if ((productFinder && path.includes(productFinder)) ||
            (lineItemsSection && path.includes(lineItemsSection))) {
            return;
        }

        if (this.showSettingsMenu) {
            const settingsMenu = this.template.querySelector('.settings-menu-container');
            if (!settingsMenu || !path.includes(settingsMenu)) {
                this.showSettingsMenu = false;
            }
        }

        if (this.showSortModal) {
            const sortModal = this.template.querySelector('.line-sort-modal');
            if (sortModal && path.includes(sortModal)) {
                return;
            }
            this.handleCancelSortModal();
        }

        if (this.showLineFieldSelectorModal) {
            const fieldSelectorModal = this.template.querySelector('.line-field-selector-modal');
            if (fieldSelectorModal && path.includes(fieldSelectorModal)) {
                return;
            }
            this.handleCloseLineFieldSelector();
        }

        this.closeProductFinderPanel();
    }

    handleSettingsMenuContainerClick(event) {
        event.stopPropagation();
    }

    handleToggleSettingsMenu(event) {
        event.stopPropagation();
        this.showSettingsMenu = !this.showSettingsMenu;
    }

    async handleSettingsSelectFields(event) {
        event.stopPropagation();
        this.showSettingsMenu = false;
        await this.handleOpenLineFieldSelector(event);
    }

    handleSettingsSort(event) {
        event.stopPropagation();
        this.showSettingsMenu = false;
        this.draftSortCriteria = cloneSortCriteria(this.sortCriteria);
        this.showSortModal = true;
    }

    handleCloseSortModal(event) {
        if (event) {
            event.stopPropagation();
        }
        this.handleCancelSortModal(event);
    }

    handleSortModalClick(event) {
        event.stopPropagation();
    }

    handleCancelSortModal(event) {
        if (event) {
            event.stopPropagation();
        }
        this.draftSortCriteria = [];
        this.showSortModal = false;
    }

    handleAddSortCriterion(event) {
        if (event) {
            event.stopPropagation();
        }
        if (!this.canAddSortCriterion) {
            return;
        }
        this.draftSortCriteria = [
            ...this.draftSortCriteria,
            createDefaultSortCriterion('', 'asc')
        ];
    }

    handleRemoveSortCriterion(event) {
        event.stopPropagation();
        const criterionId = event.currentTarget.dataset.criterionId;
        const nextCriteria = this.draftSortCriteria.filter((criterion) => criterion.id !== criterionId);
        this.draftSortCriteria = nextCriteria.length
            ? nextCriteria
            : [createDefaultSortCriterion()];
    }

    handleSortCriterionFieldChange(event) {
        const criterionId = event.currentTarget.dataset.criterionId;
        const field = event.detail.value;
        this.draftSortCriteria = this.draftSortCriteria.map((criterion) =>
            criterion.id === criterionId ? { ...criterion, field } : criterion
        );
    }

    handleSortCriterionDirectionChange(event) {
        const criterionId = event.currentTarget.dataset.criterionId;
        const direction = event.currentTarget.dataset.direction || event.target.value;
        this.draftSortCriteria = this.draftSortCriteria.map((criterion) =>
            criterion.id === criterionId ? { ...criterion, direction } : criterion
        );
    }

    handleMoveSortCriterionUp(event) {
        event.stopPropagation();
        this.moveDraftSortCriterion(event.currentTarget.dataset.criterionId, -1);
    }

    handleMoveSortCriterionDown(event) {
        event.stopPropagation();
        this.moveDraftSortCriterion(event.currentTarget.dataset.criterionId, 1);
    }

    moveDraftSortCriterion(criterionId, offset) {
        const criteria = [...this.draftSortCriteria];
        const currentIndex = criteria.findIndex((criterion) => criterion.id === criterionId);
        const targetIndex = currentIndex + offset;
        if (currentIndex < 0 || targetIndex < 0 || targetIndex >= criteria.length) {
            return;
        }
        const [moved] = criteria.splice(currentIndex, 1);
        criteria.splice(targetIndex, 0, moved);
        this.draftSortCriteria = criteria;
    }

    handleClearSortCriteria(event) {
        if (event) {
            event.stopPropagation();
        }
        this.draftSortCriteria = [createDefaultSortCriterion()];
    }

    handleApplySortCriteria(event) {
        if (event) {
            event.stopPropagation();
        }

        const validCriteria = this.draftSortCriteria.filter((criterion) => criterion.field);
        if (!validCriteria.length) {
            this.draftSortCriteria = this.draftSortCriteria.map((criterion) => ({
                ...criterion,
                field: criterion.field || ''
            }));
            this.showToast('Error', 'Select a column or delete empty sort items.', 'error');
            return;
        }

        this.sortCriteria = cloneSortCriteria(validCriteria);
        this.sortMode = SORT_MODE_COLUMN;
        this.applySortToRows();
        this.draftSortCriteria = [];
        this.showSortModal = false;
    }

    handleRowDragStart(event) {
        const rowKey = event.currentTarget.dataset.rowKey;
        if (!rowKey || this.saving) {
            event.preventDefault();
            return;
        }
        this.draggedRowKey = rowKey;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', rowKey);
    }

    handleRowDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'move';
    }

    handleRowDrop(event) {
        event.preventDefault();
        const targetRowKey = event.currentTarget.dataset.rowKey;
        const sourceRowKey = event.dataTransfer.getData('text/plain');
        if (sourceRowKey && targetRowKey && sourceRowKey !== targetRowKey) {
            this.reorderRows(sourceRowKey, targetRowKey);
        }
        this.draggedRowKey = null;
    }

    handleRowDragEnd() {
        this.draggedRowKey = null;
    }

    reorderRows(sourceRowKey, targetRowKey) {
        const rows = [...this.rows];
        const sourceIndex = rows.findIndex((row) => row.key === sourceRowKey);
        const targetIndex = rows.findIndex((row) => row.key === targetRowKey);
        if (sourceIndex < 0 || targetIndex < 0) {
            return;
        }

        const [movedRow] = rows.splice(sourceIndex, 1);
        rows.splice(targetIndex, 0, movedRow);
        this.sortMode = SORT_MODE_MANUAL;
        this.setRows(rows);
    }

    handleProductRecordClick(event) {
        event.stopPropagation();
    }

    getInvoiceLineItemRecordPageUrl(invoiceLineItemId) {
        if (!invoiceLineItemId) {
            return '';
        }
        return `/lightning/r/${INVOICE_LINE_ITEM_OBJECT_API_NAME}/${invoiceLineItemId}/view`;
    }

    // Product Finder (aligned with opportunityQuoteBuilder search behavior)
    handleAddProduct(event) {
        event?.stopPropagation();
        if (!this.recordId) {
            this.showToast('Error', 'Invoice Id is required.', 'error');
            return;
        }
        if (this.showProductFinder) {
            return;
        }
        this.openProductFinder();
    }

    openProductFinder() {
        this.clearFinderPendingSelections();
        this.showProductFinder = true;
        this.runFinderProductSearch(this.productSearchTerm || '');
        this._ignoreNextFocusSearch = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const searchInput = this.template.querySelector('.product-finder lightning-input');
            if (searchInput) {
                searchInput.focus();
            }
        });
    }

    handleProductFinderClick(event) {
        event.stopPropagation();
    }

    async handleOpenLineFieldSelector(event) {
        if (event) {
            event.stopPropagation();
        }
        this.showLineFieldSelectorModal = true;
        await this.ensureInvoiceLineFieldOptionsLoaded();
        this.draftSelectedTableColumns = [
            ...this.sanitizeSelectedTableColumns(this.selectedTableColumns)
        ];
    }

    handleCloseLineFieldSelector(event) {
        if (event) {
            event.stopPropagation();
        }
        this.showLineFieldSelectorModal = false;
        this.draftSelectedTableColumns = [];
    }

    handleInvoiceLineFieldSelectionChange(event) {
        this.draftSelectedTableColumns = this.sanitizeSelectedTableColumns(event.detail.value);
    }

    async handleApplyInvoiceLineFields(event) {
        if (event) {
            event.stopPropagation();
        }
        this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.draftSelectedTableColumns);
        this.showLineFieldSelectorModal = false;
        this.draftSelectedTableColumns = [];
        await this.mergeAdditionalInvoiceLineFieldValues();
    }

    handleFinderProductSearch(event) {
        this.productSearchTerm = event.target.value;
        clearTimeout(this.productSearchTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.productSearchTimer = setTimeout(
            () => this.runFinderProductSearch(this.productSearchTerm),
            SEARCH_DEBOUNCE_MS
        );
    }

    handleFinderProductSearchFocus() {
        if (this._ignoreNextFocusSearch) {
            this._ignoreNextFocusSearch = false;
            return;
        }
        if (!this.showProductFinder) {
            this.showProductFinder = true;
        }
        this.runFinderProductSearch(this.productSearchTerm || '');
    }

    runFinderProductSearch(searchTerm) {
        if (!this.recordId) {
            return;
        }

        searchActiveProducts({
            invoiceId: this.recordId,
            searchTerm
        })
            .then((rows) => {
                this.productSearchResults = (rows || []).map((product) =>
                    this.mapFinderProductResult(product)
                );
                this.showProductSearchResults = this.productSearchResults.length > 0;
                this.updateAddSelectedButtonState();
            })
            .catch((error) => {
                this.showProductSearchResults = false;
                this.productSearchResults = [];
                this.showToast('Product search failed', this.extractErrorMessage(error), 'error');
            });
    }

    handleSearchProductSelection(event) {
        const pbeId = event.currentTarget.dataset.pbeId;
        const checked = event.target.checked;
        const targetProduct = this.productSearchResults.find(
            (product) => product.pricebookEntryId === pbeId
        );

        if (targetProduct) {
            this.setFinderProductPendingSelection(targetProduct, checked);
        }

        this.productSearchResults = this.productSearchResults.map((product) => ({
            ...product,
            isSelected: product.pricebookEntryId === pbeId ? checked : product.isSelected
        }));

        this.updateAddSelectedButtonState();
    }

    handleCancelProductSearch(event) {
        event.stopPropagation();
        this.showProductSearchResults = false;
    }

    handleAddSearchSelectedProducts() {
        const pendingSelections = this.getPendingFinderSelections();

        if (!pendingSelections.length) {
            return;
        }

        this.addProductsFromFinder(pendingSelections);
    }

    async addProductsFromFinder(selectedProducts) {
        await this.ensureInvoiceTaxPercentLoaded();

        const newRows = selectedProducts.map((product) => this.buildRowFromFinderProduct(product));
        this.setRows(this.sortRows([...this.rows, ...newRows]), { skipTaxRefresh: true });
        this.clearFinderPendingSelections();
        this.refreshFinderProductAvailability();
        this.closeProductSearchResults();
    }

    // Row Management
    handleDeleteRow(event) {
        const rowKey = event.currentTarget.dataset.rowKey;
        const target = this.rows.find((row) => row.key === rowKey);

        if (target && target.invoiceLineItemId) {
            this.deletedLineItemIds = [...this.deletedLineItemIds, target.invoiceLineItemId];
        }

        this.setRows(this.sortRows(this.rows.filter((row) => row.key !== rowKey)));
        this.clearRowTimer(rowKey);
        this.refreshFinderProductAvailability();
    }

    handleInputChange(event) {
        const rowKey = event.target.dataset.rowKey;
        const field = event.target.dataset.field;
        if (!rowKey || !field) return;

        let value = (field === 'includeInInvoice')
            ? event.target.checked
            : (event.detail?.value ?? event.target.value);

        this.setRows(
            this.sortRows(
                this.rows.map((row) => {
                    if (row.key !== rowKey) return row;

                    const updated = { ...row, [field]: value };

                    if (field === 'cost') {
                        updated.cost = value === '' || value == null ? null : this.toNumber(value, 0);
                    } else if (field === 'quantity') {
                        const quantityError = this.getQuantityValidationError(value);
                        const salesPrice = this.toNumber(updated.salesPrice, 0);
                        const discount = this.toNumber(updated.discount, 0);
                        updated.errors = { ...updated.errors };
                        if (quantityError) {
                            updated.errors.quantity = quantityError;
                            updated.quantity = row.quantity;
                        } else {
                            updated.quantity = this.parseQuantity(value, row.quantity);
                            delete updated.errors.quantity;
                        }
                        updated.salesPrice = salesPrice;
                        updated.discount = discount;
                        updated.recalculateDiscountAmt = true;
                        updated.subtotal = this.calculateSubtotal(updated.quantity, salesPrice);
                        updated.totalPrice = this.calculateTotalPrice(
                            updated.quantity,
                            salesPrice,
                            discount
                        );
                    } else if (field === 'salesPrice') {
                        const quantity = this.parseQuantity(updated.quantity, row.quantity);
                        const salesPrice = this.toNumber(updated.salesPrice, 0);
                        const discount = this.toNumber(updated.discount, 0);
                        updated.quantity = quantity;
                        updated.salesPrice = salesPrice;
                        updated.discount = discount;
                        updated.recalculateDiscountAmt = true;
                        updated.subtotal = this.calculateSubtotal(quantity, salesPrice);
                        updated.totalPrice = this.calculateTotalPrice(quantity, salesPrice, discount);
                    } else if (field === 'discount') {
                        const quantity = this.parseQuantity(updated.quantity, row.quantity);
                        const salesPrice = this.toNumber(updated.salesPrice, 0);
                        const discount = this.toNumber(value, 0);
                        updated.quantity = quantity;
                        updated.salesPrice = salesPrice;
                        updated.discount = discount;
                        updated.recalculateDiscountAmt = true;
                        updated.subtotal = this.calculateSubtotal(quantity, salesPrice);
                        updated.totalPrice = this.calculateTotalPrice(quantity, salesPrice, discount);
                    } else if (field === 'includeInInvoice') {
                        const quantity = this.parseQuantity(updated.quantity, row.quantity);
                        const discount = this.toNumber(updated.discount, 0);

                        if (value === false) {
                            if (row.includeInInvoice !== false) {
                                updated.savedSalesPrice = this.toNumber(row.salesPrice, 0);
                            }
                            updated.salesPrice = 0;
                        } else if (row.includeInInvoice === false && updated.savedSalesPrice != null) {
                            updated.salesPrice = updated.savedSalesPrice;
                        }

                        updated.quantity = quantity;
                        updated.discount = discount;
                        updated.recalculateDiscountAmt = true;
                        updated.subtotal = this.calculateSubtotal(quantity, updated.salesPrice);
                        updated.totalPrice = this.calculateTotalPrice(
                            quantity,
                            updated.salesPrice,
                            discount
                        );
                    }

                    updated.errors = updated.errors || { ...row.errors };
                    if (field !== 'quantity') {
                        delete updated.errors[field];
                    }
                    return updated;
                })
            )
        );
    }

    // Product Search in Rows
    handleProductSearchInput(event) {
        const rowKey = event.target.dataset.rowKey;
        const term = event.target.value;

        this.setRows(
            this.rows.map((row) =>
                row.key !== rowKey
                    ? { ...row, lookupOpen: false }
                    : {
                        ...row,
                        productSearchTerm: term,
                        pricebookEntryId: null,
                        productId: null,
                        productName: '',
                        productCode: '',
                        lineItemDescription: '',
                        cost: null,
                        salesPrice: 0,
                        subtotal: this.calculateSubtotal(row.quantity, 0),
                        totalPrice: this.calculateTotalPrice(row.quantity, 0),
                        taxPercent: 0,
                        errors: { ...row.errors, product: undefined }
                    }
            )
        );

        this.debounceSearch(rowKey, term);
    }

    handleProductInputFocus(event) {
        const rowKey = event.target.dataset.rowKey;
        const row = this.rows.find((item) => item.key === rowKey);
        if (row) this.debounceSearch(rowKey, row.productSearchTerm || '');
    }

    handleSelectProduct(event) {
        const rowKey = event.currentTarget.dataset.rowKey;
        const pbeId = event.currentTarget.dataset.pbeId;

        this.selectProductForRow(rowKey, pbeId);
    }

    async selectProductForRow(rowKey, pbeId) {
        await this.ensureInvoiceTaxPercentLoaded();

        this.setRows(
            this.rows.map((row) => {
                if (row.key !== rowKey) return row;

                const selected = (row.lookupResults || []).find(
                    (item) => item.pricebookEntryId === pbeId
                );
                if (!selected) return row;

                const salesPrice = this.toNumber(selected.salesPrice, 0);
                const quantity = this.toNumber(row.quantity, 1);
                const errors = { ...row.errors };
                delete errors.product;

                return {
                    ...row,
                    pricebookEntryId: selected.pricebookEntryId,
                    productId: selected.productId,
                    productName: selected.productName || '',
                    productCode: selected.productCode || '',
                    productSearchTerm: selected.productName || '',
                    cost: this.toNullableNumber(selected.cost),
                    salesPrice,
                    quantity,
                    discount: this.toNumber(row.discount, 0),
                    discountAmt: null,
                    recalculateDiscountAmt: true,
                    subtotal: this.calculateSubtotal(quantity, salesPrice),
                    totalPrice: this.calculateTotalPrice(quantity, salesPrice, row.discount),
                    taxable: this.resolveProductTaxable(selected),
                    taxPercent: this.toNumber(this.invoiceTaxPercent, 0),
                    lineItemDescription: selected.productDescription || '',
                    lookupOpen: false,
                    lookupResults: [],
                    errors
                };
            }),
            { skipTaxRefresh: true }
        );
    }

    handleProductInputBlur() {
        window.clearTimeout(this.blurTimer);
        this.blurTimer = setTimeout(() => {
            this.setRows(this.rows.map((row) => ({ ...row, lookupOpen: false })));
        }, 150);
    }

    handleProductDropdownMouseDown(event) {
        event.preventDefault();
    }

    hasUnsavedChanges() {
        if (this.deletedLineItemIds && this.deletedLineItemIds.length > 0) {
            return true;
        }

        const currentRows = this.rows || [];
        const originalRows = this.originalRows || [];

        if (currentRows.length !== originalRows.length) {
            return true;
        }

        for (let i = 0; i < currentRows.length; i++) {
            const cur = currentRows[i];
            const orig = originalRows[i];

            if (!cur.invoiceLineItemId || cur.invoiceLineItemId !== orig.invoiceLineItemId) {
                return true;
            }

            const curCost = cur.cost ?? null;
            const origCost = orig.cost ?? null;
            if (curCost !== origCost) {
                return true;
            }

            const curDesc = cur.lineItemDescription || '';
            const origDesc = orig.lineItemDescription || '';
            if (curDesc !== origDesc) {
                return true;
            }

            if (
                cur.pricebookEntryId !== orig.pricebookEntryId ||
                cur.productId !== orig.productId ||
                cur.quantity !== orig.quantity ||
                cur.salesPrice !== orig.salesPrice ||
                cur.discount !== orig.discount ||
                cur.includeInInvoice !== orig.includeInInvoice ||
                cur.taxPercent !== orig.taxPercent
            ) {
                return true;
            }
        }

        return false;
    }

    handleSaveClick() {
        if (this.saving) {
            return;
        }
        if (this.hasUnsavedChanges()) {
            void this.handleSave();
        } else {
            this.handleCloseModal();
        }
    }

    // Save & Validation
    async handleSave() {
        this.errorMessage = '';

        // Commit the visible table order before validation and save.
        const visibleRows = this.getDisplayRows();
        this.sortMode = SORT_MODE_MANUAL;
        this.setRows(visibleRows, { skipTaxRefresh: true });

        const validationResult = this.validateRows();
        this.setRows(validationResult.rows);

        if (!validationResult.isValid) {
            this.showToast('Error', 'Fix validation errors before saving.', 'error');
            return;
        }

        this.saving = true;
        try {
            const payload = this.rows.map((row) => ({
                invoiceLineItemId: row.invoiceLineItemId || null,
                pricebookEntryId: row.pricebookEntryId,
                productId: row.productId,
                quantity: row.quantity,
                salesPrice: row.salesPrice,
                cost: row.cost,
                discount: row.discount,
                taxPercent: row.taxPercent != null ? row.taxPercent : this.toNumber(this.invoiceTaxPercent, 0),
                includeInInvoice: row.includeInInvoice,
                lineItemDescription: row.lineItemDescription || ''
            }));

            await saveInvoiceLineItems({
                request: {
                    invoiceId: this.recordId,
                    rows: payload,
                    deletedLineItemIds: this.deletedLineItemIds
                }
            });

            this.deletedLineItemIds = [];
            await this.loadRows();
            this.showToast('Success', 'Invoice Line Items saved successfully.', 'success');
            this.isModalOpen = false;
            this.showCardMenu = false;
            this.showSettingsMenu = false;
            this.showSortModal = false;
            this.draftSortCriteria = [];
            this.resetProductFinderState();
            this.unlockBackgroundScroll();
        } catch (error) {
            const message = this.extractErrorMessage(error);
            this.errorMessage = message;
            this.showToast('Error', message, 'error');
        } finally {
            this.saving = false;
        }
    }

    validateRows() {
        let valid = true;
        const updatedRows = this.rows.map((row) => {
            const errors = {};

            if (!row.pricebookEntryId && !row.productId) {
                errors.product = 'Product is required.';
                valid = false;
            }
            const quantityError = this.getQuantityValidationError(row.quantity);
            if (quantityError) {
                errors.quantity = quantityError;
                valid = false;
            }
          /*  if (row.salesPrice == null || Number(row.salesPrice) < 0) {
                errors.salesPrice = 'Sales Price cannot be negative.';
                valid = false;
            }*/

            return { ...row, errors };
        });

        return { isValid: valid, rows: updatedRows };
    }

    // Helper Methods
    buildRowFromFinderProduct(product) {
        const quantity = 1;
        const salesPrice = this.toNumber(product.salesPrice, 0);

        return {
            key: this.buildClientKey(),
            invoiceLineItemId: null,
            lineItemName: '',
            pricebookEntryId: product.pricebookEntryId,
            productId: product.productId,
            productName: product.productName || '',
            productCode: product.productCode || '',
            productSearchTerm: product.productName || '',
            cost: this.toNullableNumber(product.cost),
            salesPrice,
            quantity,
            subtotal: this.calculateSubtotal(quantity, salesPrice),
            totalPrice: this.calculateTotalPrice(quantity, salesPrice),
            includeInInvoice: true,
            taxable: this.resolveProductTaxable(product),
            taxPercent: this.toNumber(this.invoiceTaxPercent, 0),
            discount: 0,
            discountAmt: 0,
            recalculateDiscountAmt: true,
            lineItemDescription: product.productDescription || '',
            invoiceLineFieldValues: {},
            errors: {},
            lookupResults: [],
            lookupOpen: false,
            lookupLoading: false
        };
    }

    resolveProductTaxable(product) {
        if (!product) {
            return false;
        }
        if (product.taxable === true) {
            return true;
        }
        if (product.taxable === false) {
            return false;
        }

        const matchedSearchResult = (this.productSearchResults || []).find(
            (searchProduct) => searchProduct.pricebookEntryId === product.pricebookEntryId
        );
        return matchedSearchResult?.taxable === true;
    }

    async loadRows() {
        this.loading = true;
        this.errorMessage = '';
        this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.selectedTableColumns);
        try {
            if (this.recordId) {
                const recordIds = [{ recordId: this.recordId }];
                if (this.rows && this.rows.length) {
                    this.rows.forEach((row) => {
                        if (row.invoiceLineItemId) {
                            recordIds.push({ recordId: row.invoiceLineItemId });
                        }
                    });
                }
                await getRecordNotifyChange(recordIds);
            }
            const [data, summaryContext] = await Promise.all([
                getInvoiceLineItems({
                    invoiceId: this.recordId,
                    additionalFieldApiNames: this.getSelectedInvoiceLineFieldApiNames()
                }),
                getInvoiceSummaryContext({ invoiceId: this.recordId })
            ]);
            this.applyInvoiceTaxPercent(summaryContext?.taxPercent);
            // Preserve sort order from the server before syncing preview/table rows.
            this.sortMode = SORT_MODE_MANUAL;
            this.setRows((data || []).map((row) => this.mapServerRow(row)));
            this.originalRows = JSON.parse(JSON.stringify(this.rows));
            this.hasLoadedRows = true;
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
            this.showToast('Error', this.errorMessage, 'error');
            throw error;
        } finally {
            this.loading = false;
        }
    }

    async reloadLineItemsFromServer() {
        if (!this.recordId) {
            return false;
        }

        try {
            await this.loadRows();
            return true;
        } catch (error) {
            return false;
        }
    }

    handleInvoiceLineItemsChanged(message) {
        if (!this.isMatchingInvoiceRecord(message && message.recordId)) {
            return;
        }

        this.reloadLineItemsFromServer();
    }

    handleInvoiceLineItemsChangedEvent(event) {
        const recordId = event && event.detail ? event.detail.recordId : null;
        if (!this.isMatchingInvoiceRecord(recordId)) {
            return;
        }

        this.reloadLineItemsFromServer();
    }

    isMatchingInvoiceRecord(incomingRecordId) {
        if (!incomingRecordId || !this.recordId) {
            return false;
        }

        return String(incomingRecordId).toLowerCase() === String(this.recordId).toLowerCase();
    }

    mapServerRow(row) {
        const quantity = this.toNumber(row.quantity, 1);
        const serverSalesPrice = this.toNumber(row.salesPrice, 0);
        const discount = this.toNumber(row.discount, 0);
        const includeInInvoice = row.includeInInvoice !== false;
        const salesPrice = includeInInvoice ? serverSalesPrice : 0;
        const savedSalesPrice = includeInInvoice ? null : serverSalesPrice;

        return {
            key: row.invoiceLineItemId || this.buildClientKey(),
            invoiceLineItemId: row.invoiceLineItemId || null,
            lineItemName: row.lineItemName || '',
            pricebookEntryId: row.pricebookEntryId || null,
            productId: row.productId || null,
            productName: row.productName || '',
            productCode: row.productCode || '',
            productSearchTerm: row.productName || '',
            cost: this.toNullableNumber(row.cost),
            salesPrice,
            savedSalesPrice,
            quantity,
            discount,
            discountAmt: row.discountAmt != null ? this.toNumber(row.discountAmt, 0) : null,
            recalculateDiscountAmt: false,
            subtotal: this.calculateSubtotal(quantity, salesPrice),
            totalPrice: row.totalPrice != null
                ? this.toNumber(row.totalPrice, this.calculateTotalPrice(quantity, salesPrice, discount))
                : this.calculateTotalPrice(quantity, salesPrice, discount),
            taxPercent:
                row.taxPercent != null
                    ? this.toNumber(row.taxPercent, 0)
                    : this.toNumber(this.invoiceTaxPercent, 0),
            includeInInvoice,
            taxable: row.taxable === true,
            lineItemDescription: row.lineItemDescription || '',
            sortOrder: this.toNullableNumber(row.sortOrder),
            invoiceLineFieldValues: row.invoiceLineFieldValues || {},
            errors: {},
            lookupResults: [],
            lookupOpen: false,
            lookupLoading: false
        };
    }

    // Utility Methods
    clearFinderPendingSelections() {
        this._pendingFinderSelections.clear();
    }

    getFinderSelectionKey(product) {
        return product?.pricebookEntryId || null;
    }

    isFinderProductPendingSelection(pricebookEntryId) {
        return !!pricebookEntryId && this._pendingFinderSelections.has(pricebookEntryId);
    }

    setFinderProductPendingSelection(product, selected) {
        const key = this.getFinderSelectionKey(product);
        if (!key) {
            return;
        }
        if (selected) {
            this._pendingFinderSelections.set(key, {
                pricebookEntryId: product.pricebookEntryId,
                productId: product.productId,
                productName: product.productName || '',
                productCode: product.productCode || '',
                productDescription: product.productDescription || '',
                cost: product.cost,
                salesPrice: product.salesPrice,
                taxable: this.resolveProductTaxable(product)
            });
            return;
        }
        this._pendingFinderSelections.delete(key);
    }

    getPendingFinderSelections() {
        return Array.from(this._pendingFinderSelections.values());
    }

    mapFinderProductResult(product, selectionState = {}) {
        const isPendingSelected = this.isFinderProductPendingSelection(product.pricebookEntryId);
        const isSelected = selectionState.isSelected ?? isPendingSelected;
        const mapped = {
            pricebookEntryId: product.pricebookEntryId,
            productId: product.productId,
            productName: product.productName || '',
            productCode: product.productCode || '',
            productDescription: product.productDescription || '',
            cost: product.cost,
            salesPrice: product.salesPrice,
            taxable: product.taxable === true,
            isSelected,
            isCheckboxDisabled: this.saving,
            rowClass: 'product-search-result',
            formattedCost: this.formatCurrency(product.cost),
            formattedSalesPrice: this.formatCurrency(product.salesPrice)
        };
        return mapped;
    }

    refreshFinderProductAvailability() {
        if (!this.productSearchResults.length) {
            return;
        }
        this.productSearchResults = this.productSearchResults.map((product) =>
            this.mapFinderProductResult(product)
        );
        this.updateAddSelectedButtonState();
    }

    async ensureInvoiceLineFieldOptionsLoaded() {
        if (this.invoiceLineFieldOptions.length > 0 || this.invoiceLineFieldOptionsLoading) {
            return;
        }
        this.invoiceLineFieldOptionsLoading = true;
        try {
            const options = await getInvoiceLineItemFieldOptions();
            this.invoiceLineFieldOptions = (options || []).filter(
                (field) => field?.apiName && !isDefaultInvoiceLineTableField(field.apiName)
            );
            this.invoiceLineFieldLabelByApiName = {};
            this.invoiceLineFieldOptions.forEach((field) => {
                this.invoiceLineFieldLabelByApiName[field.apiName] = field.label;
            });
            this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.selectedTableColumns);
        } catch (error) {
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        } finally {
            this.invoiceLineFieldOptionsLoading = false;
        }
    }

    getSelectedInvoiceLineFieldApiNames() {
        return this.sanitizeSelectedTableColumns(this.selectedTableColumns).filter(
            (columnKey) => !isBuiltinTableColumn(columnKey)
        );
    }

    sanitizeSelectedTableColumns(columnKeys) {
        const optionApiNameByNormalized = new Map();
        (this.invoiceLineFieldOptions || []).forEach((field) => {
            if (field?.apiName) {
                optionApiNameByNormalized.set(
                    normalizeInvoiceLineFieldApiName(field.apiName),
                    field.apiName
                );
            }
        });

        const seenBuiltinKeys = new Set();
        const seenFieldKeys = new Set();
        const sanitized = [];

        (columnKeys || []).forEach((columnKey) => {
            if (!columnKey) {
                return;
            }

            if (isBuiltinTableColumn(columnKey)) {
                if (!seenBuiltinKeys.has(columnKey)) {
                    seenBuiltinKeys.add(columnKey);
                    sanitized.push(columnKey);
                }
                return;
            }

            if (isDefaultInvoiceLineTableField(columnKey)) {
                return;
            }

            const normalizedApiName = normalizeInvoiceLineFieldApiName(columnKey);
            if (seenFieldKeys.has(normalizedApiName)) {
                return;
            }

            const canonicalApiName = optionApiNameByNormalized.get(normalizedApiName);
            if (!canonicalApiName) {
                return;
            }

            seenFieldKeys.add(normalizedApiName);
            sanitized.push(canonicalApiName);
        });

        return sanitized;
    }

    getVisibleColumnDefinitions() {
        const builtinColumnByKey = new Map(
            DEFAULT_TABLE_COLUMNS.map((column) => [column.key, column])
        );

        return this.sanitizeSelectedTableColumns(this.selectedTableColumns).map((columnKey) => {
            const builtinColumn = builtinColumnByKey.get(columnKey);
            if (builtinColumn) {
                return {
                    key: builtinColumn.key,
                    label: builtinColumn.label,
                    headerClass: builtinColumn.headerClass || ''
                };
            }

            return {
                key: columnKey,
                label: this.invoiceLineFieldLabelByApiName[columnKey] || columnKey,
                headerClass: 'optional-col-header'
            };
        });
    }

    buildRowTableCells(row, columnDefinitions) {
        return (columnDefinitions || []).map((column) => {
            const cellKey = `${row.key}-${column.key}`;

            if (column.key === 'product') {
                const invoiceLineItemId = row.invoiceLineItemId || null;
                return {
                    key: cellKey,
                    isProduct: true,
                    cellClass: 'line-product-cell',
                    isProductLink: Boolean(invoiceLineItemId),
                    productDisplay: this.formatProductDisplay(row),
                    recordPageUrl: this.getInvoiceLineItemRecordPageUrl(invoiceLineItemId),
                    hasProductError: Boolean(row.errors?.product),
                    productError: row.errors?.product
                };
            }

            if (column.key === 'cost') {
                return {
                    key: cellKey,
                    isCost: true,
                    cellClass: '',
                    value: row.cost,
                    rowKey: row.key
                };
            }

            if (column.key === 'salesPrice') {
                return {
                    key: cellKey,
                    isSalesPrice: true,
                    cellClass: '',
                    value: row.salesPrice,
                    rowKey: row.key,
                    hasSalesPriceError: Boolean(row.errors?.salesPrice),
                    salesPriceError: row.errors?.salesPrice
                };
            }

            if (column.key === 'quantity') {
                return {
                    key: cellKey,
                    isQuantity: true,
                    cellClass: '',
                    value: row.quantity,
                    rowKey: row.key,
                    hasQuantityError: Boolean(row.errors?.quantity),
                    quantityError: row.errors?.quantity
                };
            }

            if (column.key === 'subtotal') {
                return {
                    key: cellKey,
                    isSubtotal: true,
                    cellClass: 'currency-display-cell',
                    displayValue: this.formatCurrency(row.subtotal)
                };
            }

            if (column.key === 'totalPrice') {
                return {
                    key: cellKey,
                    isTotalPrice: true,
                    cellClass: 'currency-display-cell',
                    displayValue: this.formatCurrency(this.getRowAmountExclTax(row))
                };
            }

            if (column.key === 'includeInInvoice') {
                return {
                    key: cellKey,
                    isIncludeInInvoice: true,
                    cellClass: 'checkbox-col',
                    checked: row.includeInInvoice,
                    rowKey: row.key
                };
            }

            if (column.key === 'lineItemDescription') {
                return {
                    key: cellKey,
                    isLineItemDescription: true,
                    cellClass: '',
                    value: row.lineItemDescription,
                    rowKey: row.key
                };
            }

            return {
                key: cellKey,
                isOptional: true,
                cellClass: 'optional-col-cell',
                displayValue: getInvoiceLineFieldMapValue(row.invoiceLineFieldValues, column.key)
            };
        });
    }

    getDisplayRows() {
        if (!this.rows.length) {
            return [];
        }
        return this.sortRows([...this.rows]);
    }

    applySortToRows() {
        this.sortMode = SORT_MODE_COLUMN;
        this.setRows(this.sortRows([...this.rows]));
    }

    sortRows(rows) {
        if (!rows.length || this.sortMode === SORT_MODE_MANUAL) {
            return rows;
        }

        const activeCriteria = (this.sortCriteria || []).filter((criterion) => criterion.field);
        if (!activeCriteria.length) {
            return rows;
        }

        return rows.sort((rowA, rowB) => {
            for (const criterion of activeCriteria) {
                const directionMultiplier = criterion.direction === 'desc' ? -1 : 1;
                const comparison = this.compareRowsForSort(rowA, rowB, criterion.field);
                if (comparison !== 0) {
                    return comparison * directionMultiplier;
                }
            }
            return 0;
        });
    }

    compareRowsForSort(rowA, rowB, sortKey) {
        if (sortKey === 'product') {
            const nameA = (rowA.productName || rowA.productSearchTerm || '').toLowerCase();
            const nameB = (rowB.productName || rowB.productSearchTerm || '').toLowerCase();
            return nameA.localeCompare(nameB);
        }

        if (sortKey === 'lineItemDescription') {
            const valueA = (rowA.lineItemDescription || '').toLowerCase();
            const valueB = (rowB.lineItemDescription || '').toLowerCase();
            return valueA.localeCompare(valueB);
        }

        if (sortKey === 'includeInInvoice') {
            const valueA = rowA.includeInInvoice === false ? 0 : 1;
            const valueB = rowB.includeInInvoice === false ? 0 : 1;
            return valueA - valueB;
        }

        const valueA = this.getRowSortValue(rowA, sortKey);
        const valueB = this.getRowSortValue(rowB, sortKey);

        if (typeof valueA === 'string' || typeof valueB === 'string') {
            const stringA = (valueA ?? '').toString().toLowerCase();
            const stringB = (valueB ?? '').toString().toLowerCase();
            return stringA.localeCompare(stringB);
        }

        if (valueA == null && valueB == null) {
            return 0;
        }
        if (valueA == null) {
            return 1;
        }
        if (valueB == null) {
            return -1;
        }

        if (valueA < valueB) {
            return -1;
        }
        if (valueA > valueB) {
            return 1;
        }
        return 0;
    }

    getRowSortValue(row, sortKey) {
        switch (sortKey) {
            case 'cost':
                return row.cost == null ? null : Number(row.cost);
            case 'salesPrice':
                return Number(row.salesPrice);
            case 'quantity':
                return Number(row.quantity);
            case 'subtotal':
                return Number(row.subtotal);
            case 'totalPrice':
                return this.getRowAmountExclTax(row);
            default: {
                const customValue = getInvoiceLineFieldMapValue(row.invoiceLineFieldValues, sortKey);
                if (!customValue.length) {
                    return null;
                }
                const numericValue = Number(customValue);
                return Number.isFinite(numericValue) ? numericValue : customValue;
            }
        }
    }

    async mergeAdditionalInvoiceLineFieldValues() {
        if (!this.recordId) {
            return;
        }

        this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.selectedTableColumns);
        const visibleFieldApiNames = this.getSelectedInvoiceLineFieldApiNames();

        if (!visibleFieldApiNames.length) {
            this.setRows(
                this.rows.map((row) => ({
                    ...row,
                    invoiceLineFieldValues: {}
                }))
            );
            return;
        }

        try {
            const data = await getInvoiceLineItems({
                invoiceId: this.recordId,
                additionalFieldApiNames: visibleFieldApiNames
            });
            const serverByInvoiceLineItemId = new Map();
            (data || []).forEach((serverRow) => {
                const mapped = this.mapServerRow(serverRow);
                if (mapped.invoiceLineItemId) {
                    serverByInvoiceLineItemId.set(mapped.invoiceLineItemId, mapped);
                }
            });

            const visibleFieldSet = new Set(visibleFieldApiNames);
            this.setRows(
                this.rows.map((row) => {
                    const serverRow = row.invoiceLineItemId
                        ? serverByInvoiceLineItemId.get(row.invoiceLineItemId)
                        : null;
                    const sourceValues = serverRow
                        ? serverRow.invoiceLineFieldValues || {}
                        : row.invoiceLineFieldValues || {};
                    const invoiceLineFieldValues = {};
                    visibleFieldSet.forEach((fieldApiName) => {
                        const value = getInvoiceLineFieldMapValue(sourceValues, fieldApiName);
                        if (value.length) {
                            invoiceLineFieldValues[fieldApiName] = value;
                        } else if (sourceValues[fieldApiName] != null) {
                            invoiceLineFieldValues[fieldApiName] = String(
                                sourceValues[fieldApiName]
                            );
                        }
                    });

                    return {
                        ...row,
                        invoiceLineFieldValues
                    };
                })
            );
        } catch (error) {
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        }
    }

    updateAddSelectedButtonState() {
        const selectedCount = this.getPendingFinderSelections().length;
        this.disableAddSearchProducts = selectedCount === 0;
        this.addSearchSelectedLabel = selectedCount ? `Add Selected (${selectedCount})` : 'Add Selected';
    }

    debounceSearch(rowKey, term) {
        this.clearRowTimer(rowKey);
        this.searchTimersByRowId[rowKey] = setTimeout(() =>
            this.runProductSearch(rowKey, term), SEARCH_DEBOUNCE_MS);
    }

    async runProductSearch(rowKey, term) {
        const reqId = ++this.requestCounter;
        this.setRows(
            this.rows.map((row) =>
                row.key === rowKey ? { ...row, lookupLoading: true, lookupOpen: false } : row
            )
        );

        try {
            const results = await searchActiveProducts({
                invoiceId: this.recordId,
                searchTerm: term || ''
            });

            this.setRows(
                this.rows.map((row) => {
                    if (row.key !== rowKey || reqId !== this.requestCounter) return row;
                    return {
                        ...row,
                        lookupResults: (results || []).map((item) => ({
                            ...item,
                            label: item.productName || ''
                        })),
                        lookupOpen: !!(results && results.length),
                        lookupLoading: false
                    };
                })
            );
        } catch (error) {
            this.setRows(
                this.rows.map((row) =>
                    row.key === rowKey
                        ? { ...row, lookupLoading: false, lookupOpen: false, lookupResults: [] }
                        : row
                )
            );
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        }
    }

    closeProductFinderPanel() {
        this.showProductFinder = false;
        clearTimeout(this.productSearchTimer);
        this.productSearchTerm = '';
        this.productSearchResults = [];
        this.clearFinderPendingSelections();
        this.closeProductSearchResults();
    }

    closeProductSearchResults() {
        this.showProductSearchResults = false;
        this.updateAddSelectedButtonState();
    }

    resetProductFinderState() {
        clearTimeout(this.productSearchTimer);
        this.clearFinderPendingSelections();
        this.showProductFinder = false;
        this.productSearchTerm = '';
        this.productSearchResults = [];
        this.showProductSearchResults = false;
        this._ignoreNextFocusSearch = false;
        this.disableAddSearchProducts = true;
        this.addSearchSelectedLabel = 'Add Selected';
    }

    clearRowTimer(rowKey) {
        const timer = this.searchTimersByRowId[rowKey];
        if (timer) {
            clearTimeout(timer);
            delete this.searchTimersByRowId[rowKey];
        }
    }

    // Pure Utility Functions
    calculateSubtotal(quantity, salesPrice) {
        return this.toNumber(quantity, 0) * this.toNumber(salesPrice, 0);
    }

    calculateTotalPrice(quantity, salesPrice, discount = 0) {
        let amount = this.calculateSubtotal(quantity, salesPrice);
        const discountPct = this.toNumber(discount, 0);
        if (discountPct !== 0) {
            amount = amount - (amount * discountPct / 100);
        }
        return Number(amount.toFixed(2));
    }

    getQuantityValidationError(value) {
        if (value === '' || value == null) {
            return 'Quantity is required.';
        }
        const num = Number(value);
        if (!Number.isFinite(num) || num <= 0) {
            return 'Quantity must be greater than zero.';
        }
        return null;
    }

    parseQuantity(value, fallback = 1) {
        const num = Number(value);
        if (!Number.isFinite(num) || num <= 0) {
            return fallback;
        }
        return num;
    }

    toNumber(value, fallback = 0) {
        const num = Number(value);
        return Number.isFinite(num) ? num : fallback;
    }

    toNullableNumber(value) {
        if (value === null || value === undefined || value === '') return null;
        const num = Number(value);
        return Number.isFinite(num) ? num : null;
    }

    buildClientKey() {
        return `row-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
    }

    formatCurrency(value) {
        const numeric = this.toNumber(value, 0);
        return new Intl.NumberFormat('en-US', {
            style: 'currency',
            currency: 'USD'
        }).format(numeric);
    }

    extractErrorMessage(error) {
        if (!error) return 'Unexpected error.';
        const body = error.body || {};

        if (Array.isArray(body.output?.errors) && body.output.errors.length) {
            return body.output.errors.map((e) => e.message).join(' ');
        }
        if (Array.isArray(body.pageErrors) && body.pageErrors.length) {
            return body.pageErrors.map((e) => e.message).join(' ');
        }
        if (body.message) return body.message;
        if (error.message) return error.message;

        return 'Unexpected error.';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}