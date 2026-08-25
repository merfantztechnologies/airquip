import { LightningElement, api, track } from 'lwc';
import { loadStyle } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import modal from '@salesforce/resourceUrl/modalPopup';
import getQuoteLineItems from '@salesforce/apex/QuoteLineItemEditorController.getQuoteLineItems';
import getQuoteLineItemFieldOptions from '@salesforce/apex/QuoteLineItemEditorController.getQuoteLineItemFieldOptions';
import searchActiveProducts from '@salesforce/apex/QuoteLineItemEditorController.searchActiveProducts';
import saveQuoteLineItems from '@salesforce/apex/QuoteLineItemEditorController.saveQuoteLineItems';

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
    { label: 'Include In Quote', value: 'includeInQuote' }
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
    { key: 'includeInQuote', label: 'Include In Quote', headerClass: 'checkbox-col' }
];

const BUILTIN_TABLE_COLUMN_KEYS = new Set(DEFAULT_TABLE_COLUMNS.map((column) => column.key));

const FIELD_SELECTOR_EXCLUDED_BUILTIN_KEYS = new Set(['cost', 'totalPrice']);

const FIELD_SELECTOR_EXCLUDED_FIELD_API_NAMES = new Set([
    'cost__c',
    'totalprice',
    'costs__c',
    'total_price__c',
    'quantity__c'
]);

const DEFAULT_SELECTED_TABLE_COLUMNS = DEFAULT_TABLE_COLUMNS.map((column) => column.key);

const DEFAULT_QUOTE_LINE_TABLE_FIELD_API_NAMES = new Set([
    'cost__c',
    'unitprice',
    'quantity',
    'quantity__c',
    'subtotal',
    'totalprice',
    'costs__c',
    'total_price__c',
    'include_in_quote__c',
    'line_item_description__c',
    'description',
    'listprice',
    'discount'
]);

function normalizeQuoteLineFieldApiName(apiName) {
    return (apiName || '').trim().toLowerCase();
}

function isDefaultQuoteLineTableField(apiName) {
    return DEFAULT_QUOTE_LINE_TABLE_FIELD_API_NAMES.has(normalizeQuoteLineFieldApiName(apiName));
}

function isBuiltinTableColumn(columnKey) {
    return BUILTIN_TABLE_COLUMN_KEYS.has(columnKey);
}

function isFieldSelectorExcludedColumn(columnKey) {
    if (!columnKey) {
        return false;
    }
    if (FIELD_SELECTOR_EXCLUDED_BUILTIN_KEYS.has(columnKey)) {
        return true;
    }
    return FIELD_SELECTOR_EXCLUDED_FIELD_API_NAMES.has(normalizeQuoteLineFieldApiName(columnKey));
}

function getQuoteLineFieldMapValue(fieldValues, fieldApiName) {
    if (!fieldValues || !fieldApiName) {
        return '';
    }
    if (fieldValues[fieldApiName] != null && String(fieldValues[fieldApiName]).length) {
        return String(fieldValues[fieldApiName]);
    }
    const target = normalizeQuoteLineFieldApiName(fieldApiName);
    for (const key of Object.keys(fieldValues)) {
        if (normalizeQuoteLineFieldApiName(key) === target) {
            const value = fieldValues[key];
            return value != null && String(value).length ? String(value) : '';
        }
    }
    return '';
}

const QUOTE_LINE_ITEM_OBJECT_API_NAME = 'QuoteLineItem';

export default class QuoteLineItemEditor extends LightningElement {
    @api recordId;

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
    @track quoteLineFieldOptions = [];
    @track quoteLineFieldOptionsLoading = false;
    @track selectedTableColumns = [...DEFAULT_SELECTED_TABLE_COLUMNS];
    @track draftSelectedTableColumns = [];
    @track previewLineItems = [];

    deletedLineItemIds = [];
    quoteLineFieldLabelByApiName = {};
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

    connectedCallback() {
        loadStyle(this, modal);
        this.loadRows();
        this.documentClickHandler = this.handleDocumentClick.bind(this);
        document.addEventListener('click', this.documentClickHandler);
    }

    disconnectedCallback() {
        if (this.documentClickHandler) {
            document.removeEventListener('click', this.documentClickHandler);
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

    setRows(rows) {
        this.rows = rows;
        this.syncPreviewLineItems();
    }

    getPreviewSourceRows() {
        return this.getDisplayRows().filter((row) => this.isPreviewableRow(row));
    }

    isPreviewableRow(row) {
        return !!(row && (row.pricebookEntryId || row.productId));
    }

    syncPreviewLineItems() {
        this.previewLineItems = this.getPreviewSourceRows()
            .slice(0, 3)
            .map((row, index) => ({
                key: row.key || `preview-${index}`,
                productName: this.formatPreviewProductName(row),
                cost: this.formatCurrency(row.cost),
                salesPrice: this.formatCurrency(row.salesPrice),
                quantity: row.quantity ?? '0'
            }));
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
        const builtinOptions = DEFAULT_TABLE_COLUMNS.filter(
            (column) => !isFieldSelectorExcludedColumn(column.key)
        ).map((column) => ({
            label: column.label,
            value: column.key
        }));
        const fieldOptions = (this.quoteLineFieldOptions || [])
            .filter((field) => !isFieldSelectorExcludedColumn(field.apiName))
            .map((field) => ({
                label: field.label,
                value: field.apiName
            }));
        return [...builtinOptions, ...fieldOptions];
    }

    get hasTableColumnPickerOptions() {
        return this.tableColumnPickerOptions.length > 0;
    }

    get sortFieldOptions() {
        const optionalFieldOptions = (this.quoteLineFieldOptions || []).map((field) => ({
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
            rowClass: this.draggedRowKey === row.key ? 'quote-line-row quote-line-row_dragging' : 'quote-line-row',
            isDraggable: !this.saving,
            productDisplay: this.formatProductDisplay(row),
            subtotalDisplay: this.formatCurrency(row.subtotal),
            totalPriceDisplay: this.formatCurrency(row.totalPrice),
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
    handleOpenModal() {
        this.isModalOpen = true;
        this.lockBackgroundScroll();
        if (this.recordId) {
            this.loadRows();
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

    getQuoteLineItemRecordPageUrl(quoteLineItemId) {
        if (!quoteLineItemId) {
            return '';
        }
        return `/lightning/r/${QUOTE_LINE_ITEM_OBJECT_API_NAME}/${quoteLineItemId}/view`;
    }

    // Product Finder (aligned with opportunityQuoteBuilder search behavior)
    handleAddProduct(event) {
        event?.stopPropagation();
        if (!this.recordId) {
            this.showToast('Error', 'Quote Id is required.', 'error');
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
        await this.ensureQuoteLineFieldOptionsLoaded();
        this.draftSelectedTableColumns = [
            ...this.getPickerSelectedTableColumns(this.selectedTableColumns)
        ];
    }

    handleCloseLineFieldSelector(event) {
        if (event) {
            event.stopPropagation();
        }
        this.showLineFieldSelectorModal = false;
        this.draftSelectedTableColumns = [];
    }

    handleQuoteLineFieldSelectionChange(event) {
        this.draftSelectedTableColumns = this.getPickerSelectedTableColumns(event.detail.value);
    }

    async handleApplyQuoteLineFields(event) {
        if (event) {
            event.stopPropagation();
        }
        this.selectedTableColumns = this.mergeTableColumnsWithFixedColumns(this.draftSelectedTableColumns);
        this.showLineFieldSelectorModal = false;
        this.draftSelectedTableColumns = [];
        await this.mergeAdditionalQuoteLineFieldValues();
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
            quoteId: this.recordId,
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

        const newRows = pendingSelections.map((product) => this.buildRowFromFinderProduct(product));
        this.setRows(this.sortRows([...this.rows, ...newRows]));
        this.clearFinderPendingSelections();
        this.refreshFinderProductAvailability();
        this.closeProductSearchResults();
    }

    // Row Management
    handleDeleteRow(event) {
        const rowKey = event.currentTarget.dataset.rowKey;
        const target = this.rows.find((row) => row.key === rowKey);

        if (target && target.quoteLineItemId) {
            this.deletedLineItemIds = [...this.deletedLineItemIds, target.quoteLineItemId];
        }

        this.setRows(this.sortRows(this.rows.filter((row) => row.key !== rowKey)));
        this.clearRowTimer(rowKey);
        this.refreshFinderProductAvailability();
    }

    handleInputChange(event) {
        const rowKey = event.target.dataset.rowKey;
        const field = event.target.dataset.field;
        if (!rowKey || !field) return;

        let value = (field === 'includeInQuote') 
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
                        updated.errors = { ...updated.errors };
                        if (quantityError) {
                            updated.errors.quantity = quantityError;
                            updated.quantity = row.quantity;
                        } else {
                            updated.quantity = this.parseQuantity(value, row.quantity);
                            delete updated.errors.quantity;
                        }
                        updated.salesPrice = salesPrice;
                        updated.subtotal = this.calculateSubtotal(updated.quantity, salesPrice);
                        updated.totalPrice = this.calculateTotalPrice(updated.quantity, salesPrice);
                    } else if (field === 'salesPrice') {
                        const quantity = this.parseQuantity(updated.quantity, row.quantity);
                        const salesPrice = this.toNumber(updated.salesPrice, 0);
                        updated.quantity = quantity;
                        updated.salesPrice = salesPrice;
                        updated.subtotal = this.calculateSubtotal(quantity, salesPrice);
                        updated.totalPrice = this.calculateTotalPrice(quantity, salesPrice);
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
                    subtotal: this.calculateSubtotal(quantity, salesPrice),
                    totalPrice: this.calculateTotalPrice(quantity, salesPrice),
                    lineItemDescription: selected.productDescription || '',
                    lookupOpen: false,
                    lookupResults: [],
                    errors
                };
            })
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

    // Save & Validation
    async handleSave() {
        this.errorMessage = '';

        // Commit the visible table order before validation and save.
        const visibleRows = this.getDisplayRows();
        this.sortMode = SORT_MODE_MANUAL;
        this.setRows(visibleRows);

        const validationResult = this.validateRows();
        this.setRows(validationResult.rows);

        if (!validationResult.isValid) {
            this.showToast('Error', 'Fix validation errors before saving.', 'error');
            return;
        }

        this.saving = true;
        try {
            const payload = this.rows.map((row) => ({
                quoteLineItemId: row.quoteLineItemId || null,
                pricebookEntryId: row.pricebookEntryId,
                quantity: row.quantity,
                salesPrice: row.salesPrice,
                cost: row.cost,
                includeInQuote: row.includeInQuote,
                lineItemDescription: row.lineItemDescription || ''
            }));

            await saveQuoteLineItems({
                request: { 
                    quoteId: this.recordId, 
                    rows: payload, 
                    deletedLineItemIds: this.deletedLineItemIds 
                }
            });

            this.deletedLineItemIds = [];
            await this.loadRows();
            this.showToast('Success', 'Quote Line Items saved successfully.', 'success');
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

            if (!row.pricebookEntryId) {
                errors.product = 'Product is required.';
                valid = false;
            }
            const quantityError = this.getQuantityValidationError(row.quantity);
            if (quantityError) {
                errors.quantity = quantityError;
                valid = false;
            }
            if (row.salesPrice == null || Number(row.salesPrice) < 0) {
                errors.salesPrice = 'Sales Price cannot be negative.';
                valid = false;
            }

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
            quoteLineItemId: null,
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
            includeInQuote: true,
            lineItemDescription: product.productDescription || '',
            quoteLineFieldValues: {},
            errors: {},
            lookupResults: [],
            lookupOpen: false,
            lookupLoading: false
        };
    }

    async loadRows() {
        this.loading = true;
        this.errorMessage = '';
        this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.selectedTableColumns);
        try {
            const data = await getQuoteLineItems({
                quoteId: this.recordId,
                additionalFieldApiNames: this.getSelectedQuoteLineFieldApiNames()
            });
            this.setRows((data || []).map((row) => this.mapServerRow(row)));
            // Preserve SortOrder from the server; do not re-apply column sort on load.
            this.sortMode = SORT_MODE_MANUAL;
            this.hasLoadedRows = true;
        } catch (error) {
            this.errorMessage = this.extractErrorMessage(error);
            this.showToast('Error', this.errorMessage, 'error');
        } finally {
            this.loading = false;
        }
    }

    mapServerRow(row) {
        const quantity = this.toNumber(row.quantity, 1);
        const salesPrice = this.toNumber(row.salesPrice, 0);

        return {
            key: row.quoteLineItemId || this.buildClientKey(),
            quoteLineItemId: row.quoteLineItemId || null,
            pricebookEntryId: row.pricebookEntryId || null,
            productId: row.productId || null,
            productName: row.productName || '',
            productCode: row.productCode || '',
            productSearchTerm: row.productName || '',
            cost: this.toNullableNumber(row.cost),
            salesPrice,
            quantity,
            subtotal: this.calculateSubtotal(quantity, salesPrice),
            totalPrice: this.calculateTotalPrice(quantity, salesPrice),
            includeInQuote: row.includeInQuote !== false,
            lineItemDescription: row.lineItemDescription || '',
            quoteLineFieldValues: row.quoteLineFieldValues || {},
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
                salesPrice: product.salesPrice
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

    async ensureQuoteLineFieldOptionsLoaded() {
        if (this.quoteLineFieldOptions.length > 0 || this.quoteLineFieldOptionsLoading) {
            return;
        }
        this.quoteLineFieldOptionsLoading = true;
        try {
            const options = await getQuoteLineItemFieldOptions();
            this.quoteLineFieldOptions = (options || []).filter(
                (field) =>
                    field?.apiName &&
                    !isDefaultQuoteLineTableField(field.apiName) &&
                    !isFieldSelectorExcludedColumn(field.apiName)
            );
            this.quoteLineFieldLabelByApiName = {};
            this.quoteLineFieldOptions.forEach((field) => {
                this.quoteLineFieldLabelByApiName[field.apiName] = field.label;
            });
            this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.selectedTableColumns);
        } catch (error) {
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        } finally {
            this.quoteLineFieldOptionsLoading = false;
        }
    }

    getSelectedQuoteLineFieldApiNames() {
        return this.sanitizeSelectedTableColumns(this.selectedTableColumns).filter(
            (columnKey) => !isBuiltinTableColumn(columnKey)
        );
    }

    getPickerSelectedTableColumns(columnKeys) {
        return this.sanitizeSelectedTableColumns(columnKeys).filter(
            (columnKey) => !isFieldSelectorExcludedColumn(columnKey)
        );
    }

    mergeTableColumnsWithFixedColumns(pickerSelectedKeys) {
        const pickerKeys = this.getPickerSelectedTableColumns(pickerSelectedKeys);
        const pickerKeySet = new Set(pickerKeys);
        const merged = [];

        DEFAULT_TABLE_COLUMNS.forEach((column) => {
            if (FIELD_SELECTOR_EXCLUDED_BUILTIN_KEYS.has(column.key)) {
                merged.push(column.key);
                return;
            }
            if (isBuiltinTableColumn(column.key) && pickerKeySet.has(column.key)) {
                merged.push(column.key);
            }
        });

        pickerKeys.forEach((columnKey) => {
            if (!isBuiltinTableColumn(columnKey) && !merged.includes(columnKey)) {
                merged.push(columnKey);
            }
        });

        return merged;
    }

    sanitizeSelectedTableColumns(columnKeys) {
        const optionApiNameByNormalized = new Map();
        (this.quoteLineFieldOptions || []).forEach((field) => {
            if (field?.apiName) {
                optionApiNameByNormalized.set(
                    normalizeQuoteLineFieldApiName(field.apiName),
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

            if (isDefaultQuoteLineTableField(columnKey)) {
                return;
            }

            const normalizedApiName = normalizeQuoteLineFieldApiName(columnKey);
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

        return this.mergeTableColumnsWithFixedColumns(this.selectedTableColumns).map((columnKey) => {
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
                label: this.quoteLineFieldLabelByApiName[columnKey] || columnKey,
                headerClass: 'optional-col-header'
            };
        });
    }

    buildRowTableCells(row, columnDefinitions) {
        return (columnDefinitions || []).map((column) => {
            const cellKey = `${row.key}-${column.key}`;

            if (column.key === 'product') {
                const quoteLineItemId = row.quoteLineItemId || null;
                return {
                    key: cellKey,
                    isProduct: true,
                    isProductLink: Boolean(quoteLineItemId),
                    quoteLineItemId,
                    recordPageUrl: this.getQuoteLineItemRecordPageUrl(quoteLineItemId),
                    cellClass: 'line-product-cell',
                    productDisplay: this.formatProductDisplay(row),
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
                    displayValue: this.formatCurrency(row.totalPrice)
                };
            }

            if (column.key === 'includeInQuote') {
                return {
                    key: cellKey,
                    isIncludeInQuote: true,
                    cellClass: 'checkbox-col',
                    checked: row.includeInQuote,
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
                displayValue: getQuoteLineFieldMapValue(row.quoteLineFieldValues, column.key)
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

        if (sortKey === 'includeInQuote') {
            const valueA = rowA.includeInQuote === false ? 0 : 1;
            const valueB = rowB.includeInQuote === false ? 0 : 1;
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
                return Number(row.totalPrice);
            default: {
                const customValue = getQuoteLineFieldMapValue(row.quoteLineFieldValues, sortKey);
                if (!customValue.length) {
                    return null;
                }
                const numericValue = Number(customValue);
                return Number.isFinite(numericValue) ? numericValue : customValue;
            }
        }
    }

    async mergeAdditionalQuoteLineFieldValues() {
        if (!this.recordId) {
            return;
        }

        this.selectedTableColumns = this.sanitizeSelectedTableColumns(this.selectedTableColumns);
        const visibleFieldApiNames = this.getSelectedQuoteLineFieldApiNames();

        if (!visibleFieldApiNames.length) {
            this.setRows(
                this.rows.map((row) => ({
                    ...row,
                    quoteLineFieldValues: {}
                }))
            );
            return;
        }

        try {
            const data = await getQuoteLineItems({
                quoteId: this.recordId,
                additionalFieldApiNames: visibleFieldApiNames
            });
            const serverByQuoteLineItemId = new Map();
            (data || []).forEach((serverRow) => {
                const mapped = this.mapServerRow(serverRow);
                if (mapped.quoteLineItemId) {
                    serverByQuoteLineItemId.set(mapped.quoteLineItemId, mapped);
                }
            });

            const visibleFieldSet = new Set(visibleFieldApiNames);
            this.setRows(
                this.rows.map((row) => {
                    const serverRow = row.quoteLineItemId
                        ? serverByQuoteLineItemId.get(row.quoteLineItemId)
                        : null;
                    const sourceValues = serverRow
                        ? serverRow.quoteLineFieldValues || {}
                        : row.quoteLineFieldValues || {};
                    const quoteLineFieldValues = {};
                    visibleFieldSet.forEach((fieldApiName) => {
                        const value = getQuoteLineFieldMapValue(sourceValues, fieldApiName);
                        if (value.length) {
                            quoteLineFieldValues[fieldApiName] = value;
                        } else if (sourceValues[fieldApiName] != null) {
                            quoteLineFieldValues[fieldApiName] = String(sourceValues[fieldApiName]);
                        }
                    });

                    return {
                        ...row,
                        quoteLineFieldValues
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
                quoteId: this.recordId,
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

    calculateTotalPrice(quantity, salesPrice) {
        return this.calculateSubtotal(quantity, salesPrice);
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
            return [...new Set(body.output.errors.map((e) => e.message).filter(Boolean))].join(' ');
        }
        if (Array.isArray(body.pageErrors) && body.pageErrors.length) {
            return [...new Set(body.pageErrors.map((e) => e.message).filter(Boolean))].join(' ');
        }
        if (body.message) return body.message;
        if (error.message) return error.message;

        return 'Unexpected error.';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}