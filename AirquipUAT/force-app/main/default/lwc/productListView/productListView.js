import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getProductListViews from '@salesforce/apex/ProductTriggerHandler.getProductListViews';
import browseProductsForListView from '@salesforce/apex/ProductTriggerHandler.browseProductsForListView';
import searchProductsForListView from '@salesforce/apex/ProductTriggerHandler.searchProductsForListView';
import getProductListViewFieldOptions from '@salesforce/apex/ProductTriggerHandler.getProductListViewFieldOptions';
import getProductFamilyPicklistValues from '@salesforce/apex/ProductTriggerHandler.getProductFamilyPicklistValues';
import getProductListViewDisplayConfigs from '@salesforce/apex/ProductTriggerHandler.getProductListViewDisplayConfigs';
import saveProductListViewDisplayConfig from '@salesforce/apex/ProductTriggerHandler.saveProductListViewDisplayConfig';
import deleteProductListViewDisplayConfig from '@salesforce/apex/ProductTriggerHandler.deleteProductListViewDisplayConfig';
import updateProductsForListView from '@salesforce/apex/ProductTriggerHandler.updateProductsForListView';

const OBJECT_API_NAME = 'Product2';
const PAGE_SIZE = 100;
const SEARCH_DEBOUNCE_MS = 350;
const MANDATORY_COLUMN_FIELDS = ['Name', 'ProductCode'];
const INLINE_EDITABLE_FIELDS = new Set([
    'ProductCode',
    'Family',
    'IsActive',
    'StockKeepingUnit',
    'Description',
    'faxa__Purchase_Cost__c',
    'faxa__Sales_Price__c'
]);

const ALL_PRODUCTS_VIEW_KEY = 'AllProducts';

const COLUMN_DEFS = [
    { fieldName: 'Name', label: 'Product Name', type: 'text', editable: false },
    { fieldName: 'ProductCode', label: 'Product Code', type: 'text', editable: true },
    { fieldName: 'Family', label: 'Product Family', type: 'text', editable: true },
    { fieldName: 'IsActive', label: 'Active', type: 'boolean', editable: true },
    { fieldName: 'StockKeepingUnit', label: 'SKU', type: 'text', editable: true },
    { fieldName: 'Description', label: 'Product Description', type: 'text', editable: true },
    { fieldName: 'faxa__Purchase_Cost__c', label: 'Purchase Cost', type: 'currency', editable: true },
    { fieldName: 'faxa__Sales_Price__c', label: 'Sales Price', type: 'currency', editable: true },
    { fieldName: 'faxa__In_Hand_Quantity__c', label: 'In Hand Quantity', type: 'number', editable: false },
    { fieldName: 'CreatedDate', label: 'Created Date', type: 'date', editable: false },
    { fieldName: 'LastModifiedDate', label: 'Last Modified Date', type: 'date', editable: false }
];

const DEFAULT_COLUMN_FIELDS = ['Name', 'ProductCode', 'Family', 'IsActive', 'StockKeepingUnit'];
const DATATABLE_SCROLLBAR_PAD = '20px';

export default class ProductListView extends NavigationMixin(LightningElement) {
    pageSize = PAGE_SIZE;

    @track listViewOptions = [];
    @track selectedListViewApiName = 'AllProducts';
    @track searchTerm = '';
    @track familyFilter = '';
    @track activeFilter = 'all';
    @track sortField = 'Name';
    @track sortDirection = 'ASC';
    @track pageNumber = 1;
    @track tableRows = [];
    @track tableColumns = [];
    @track totalCount = 0;
    @track hasMore = false;
    @track loading = true;
    @track isTableRefreshing = false;
    @track errorMessage;
    @track isSearchMode = false;
    @track selectedColumnFields = [...DEFAULT_COLUMN_FIELDS];
    @track showColumnModal = false;
    @track showCreateViewModal = false;
    @track newViewLabel = '';
    @track newViewFamilyFilter = '';
    @track newViewActiveFilter = 'all';
    @track customViews = [];
    @track isLoadingMore = false;
    @track fieldPickerOptions = [];
    @track familyPicklistOptions = [{ label: 'All Families', value: '' }];
    @track draftValues = [];
    @track tableErrors;

    rawRows = [];
    baseListViewOptions = [];
    serverTotalCount = 0;
    searchTimer;
    columnDefByField = new Map();
    configByKey = {};

    connectedCallback() {
        this.initialize();
    }

    disconnectedCallback() {
        clearTimeout(this.searchTimer);
    }

    async initialize() {
        this.loading = true;
        this.errorMessage = undefined;
        try {
            await this.loadFieldOptions();
            await this.loadFamilyPicklistOptions();
            await this.loadOrgDisplayConfigs();
            await this.loadListViewOptions();
            this.rebuildListViewOptions();
            this.restoreViewPreferences();
            this.ensureColumnDefsForFields(this.selectedColumnFields);
            await this.loadProducts();
        } catch (error) {
            this.handleError(error);
        } finally {
            this.loading = false;
        }
    }

    get allColumnDefs() {
        if (this.columnDefByField.size > 0) {
            return Array.from(this.columnDefByField.values());
        }
        return COLUMN_DEFS;
    }

    get columnOptions() {
        if (this.fieldPickerOptions.length > 0) {
            return this.fieldPickerOptions;
        }
        return COLUMN_DEFS.map((col) => ({ label: col.label, value: col.fieldName }));
    }

    get activeFilterOptions() {
        return [
            { label: 'All', value: 'all' },
            { label: 'Active', value: 'active' },
            { label: 'Inactive', value: 'inactive' }
        ];
    }

    get familyOptions() {
        return this.familyPicklistOptions;
    }

    get selectedColumnCountLabel() {
        return `${this.selectedColumnFields.length} columns`;
    }

    get sortedBy() {
        // Name column uses fieldName 'recordUrl' in the datatable; Apex still sorts by Name.
        return this.sortField === 'Name' ? 'recordUrl' : this.sortField;
    }

    get sortedDirection() {
        return String(this.sortDirection || 'ASC').toUpperCase() === 'DESC' ? 'desc' : 'asc';
    }

    get isInitialLoading() {
        return this.loading && !this.isTableRefreshing;
    }

    get searchModeBanner() {
        return this.isSearchMode
            ? `Searching all ${this.totalCount} matching products (not limited to the first 2,000 list view rows).`
            : '';
    }

    get recordCountLabel() {
        const loadedCount = this.rawRows.length;
        const total = this.serverTotalCount || loadedCount;
        return `${loadedCount} loaded${this.hasMore ? ' • scroll for more' : ''} • ${total} total`;
    }

    get showEmptyState() {
        return !this.isInitialLoading && !this.errorMessage && this.tableRows.length === 0;
    }

    get showDatatable() {
        return !this.isInitialLoading && this.tableColumns.length > 0 && this.tableRows.length > 0;
    }

    get isCustomViewSelected() {
        return this.selectedListViewApiName.startsWith('custom__');
    }

    get disableDeleteMenuItem() {
        return !this.isCustomViewSelected;
    }

    async loadListViewOptions() {
        try {
            const options = await getProductListViews();
            this.baseListViewOptions = (options || []).map((row) => ({
                label: row.label,
                value: row.apiName
            }));
            if (!this.baseListViewOptions.length) {
                this.baseListViewOptions = [{ label: 'All Products', value: 'AllProducts' }];
            }
        } catch (error) {
            this.baseListViewOptions = [{ label: 'All Products', value: 'AllProducts' }];
        }
    }

    async loadOrgDisplayConfigs() {
        try {
            const configs = await getProductListViewDisplayConfigs();
            const byKey = {};
            const customViews = [];
            (configs || []).forEach((cfg) => {
                if (!cfg?.viewKey) {
                    return;
                }
                byKey[cfg.viewKey] = cfg;
                if (cfg.isCustom) {
                    customViews.push({
                        id: cfg.viewKey.startsWith('custom__')
                            ? cfg.viewKey.substring('custom__'.length)
                            : cfg.viewKey,
                        label: cfg.viewLabel || cfg.viewKey,
                        selectedColumnFields: cfg.selectedColumnFields || [],
                        familyFilter: cfg.familyFilter || '',
                        activeFilter: cfg.activeFilter || 'all',
                        sortField: cfg.sortField || 'Name',
                        sortDirection: cfg.sortDirection || 'ASC'
                    });
                }
            });
            this.configByKey = byKey;
            this.customViews = customViews;
        } catch (error) {
            this.configByKey = {};
            this.customViews = [];
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not load shared display settings',
                    message: this.reduceErrors(error),
                    variant: 'warning',
                    mode: 'sticky'
                })
            );
        }
    }

    async loadFamilyPicklistOptions() {
        try {
            const values = await getProductFamilyPicklistValues();
            this.familyPicklistOptions = [
                { label: 'All Families', value: '' },
                ...(values || []).map((entry) => ({
                    label: entry.label,
                    value: entry.value
                }))
            ];
        } catch (error) {
            this.familyPicklistOptions = [{ label: 'All Families', value: '' }];
        }
    }

    async loadFieldOptions() {
        try {
            const fields = await getProductListViewFieldOptions();
            this.fieldPickerOptions = (fields || [])
                .filter((field) => field?.apiName)
                .map((field) => ({
                    label: field.label || this.toLabel(field.apiName),
                    value: field.apiName
                }));
            this.columnDefByField = new Map(COLUMN_DEFS.map((col) => [col.fieldName, { ...col }]));
            (fields || []).forEach((field) => {
                if (!field?.apiName) {
                    return;
                }
                const existing = this.columnDefByField.get(field.apiName);
                const def = {
                    fieldName: field.apiName,
                    label: field.label || this.toLabel(field.apiName),
                    type: field.datatableType || 'text',
                    editable: !!field.editable && INLINE_EDITABLE_FIELDS.has(field.apiName)
                };
                if (existing) {
                    this.columnDefByField.set(field.apiName, {
                        ...existing,
                        label: def.label,
                        type: existing.type || def.type
                    });
                } else {
                    this.columnDefByField.set(field.apiName, def);
                }
            });
        } catch (error) {
            this.fieldPickerOptions = [];
            this.columnDefByField = new Map(COLUMN_DEFS.map((col) => [col.fieldName, { ...col }]));
        }
    }

    rebuildListViewOptions() {
        const customOptions = this.customViews.map((view) => ({
            label: view.label,
            value: `custom__${view.id}`
        }));
        this.listViewOptions = [...this.baseListViewOptions, ...customOptions];
        const allProductsOption = this.baseListViewOptions.find(
            (opt) =>
                opt.value === ALL_PRODUCTS_VIEW_KEY ||
                (opt.label && opt.label.trim().toLowerCase() === 'all products')
        );
        if (allProductsOption && !this.isCustomViewSelected) {
            this.selectedListViewApiName = allProductsOption.value;
        }
        const selectedExists = this.listViewOptions.some((opt) => opt.value === this.selectedListViewApiName);
        if (!selectedExists) {
            this.selectedListViewApiName = this.baseListViewOptions[0].value;
        }
    }

    async loadProducts() {
        this.pageNumber = 1;
        this.rawRows = [];
        this.serverTotalCount = 0;
        await this.loadMoreProducts(false);
    }

    async loadMoreProducts(append) {
        const term = (this.searchTerm || '').trim();
        this.isSearchMode = !!term;
        this.errorMessage = undefined;

        const sortField = this.sortField || 'Name';
        const sortDirection = this.sortDirection || 'ASC';
        const displayFields = this.selectedColumnFields || [];
        const requestParams = {
            pageSize: this.pageSize,
            sortField,
            sortDirection,
            displayFields,
            familyFilter: this.familyFilter || null,
            activeFilter: this.activeFilter || 'all',
            lastRecordId: null,
            lastSortValue: null
        };

        if (append && this.rawRows.length > 0) {
            const lastRow = this.rawRows[this.rawRows.length - 1];
            requestParams.lastRecordId = lastRow.Id;
            requestParams.lastSortValue = this.serializeSortValue(lastRow[sortField]);
            requestParams.pageNumber = 1;
        } else {
            requestParams.pageNumber = 1;
        }

        const result = term
            ? await searchProductsForListView({
                  searchTerm: term,
                  ...requestParams
              })
            : await browseProductsForListView(requestParams);

        this.pageNumber = append ? this.pageNumber + 1 : 1;
        this.applyResult(result, append);
    }

    serializeSortValue(value) {
        if (value === undefined || value === null) {
            return null;
        }
        if (value instanceof Date) {
            return value.toISOString();
        }
        if (typeof value === 'number' && Number.isFinite(value)) {
            return String(value);
        }
        if (typeof value === 'boolean') {
            return value ? 'true' : 'false';
        }
        const text = String(value).trim();
        return text === '' ? null : text;
    }

    applyResult(result, append) {
        this.hasMore = !!result?.hasMore;
        this.serverTotalCount = result?.totalCount || 0;
        const nextRows = this.mapApexRows(result?.records || []);
        this.rawRows = append ? [...this.rawRows, ...nextRows] : nextRows;
        this.applyClientFilters();
    }

    applyClientFilters() {
        this.tableRows = [...this.rawRows];
        this.totalCount = this.serverTotalCount || this.tableRows.length;
        this.tableColumns = this.buildColumns();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => this.applyDatatableScrollbarGutter());
    }

    renderedCallback() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => this.applyDatatableScrollbarGutter());
    }

    applyDatatableScrollbarGutter() {
        const datatable = this.template.querySelector('lightning-datatable.products-datatable');
        if (!datatable?.shadowRoot) {
            return;
        }
        const pad = DATATABLE_SCROLLBAR_PAD;
        const seen = new Set();
        datatable.shadowRoot.querySelectorAll('.slds-scrollable_y, [class*="scrollable_y"]').forEach((el) => {
            if (seen.has(el)) {
                return;
            }
            seen.add(el);
            el.style.paddingRight = pad;
            el.style.scrollbarGutter = 'stable';
            el.style.boxSizing = 'border-box';
        });
    }

    buildColumns() {
        const columns = [];
        this.ensureColumnDefsForFields(this.selectedColumnFields);
        const defByField = new Map(this.allColumnDefs.map((def) => [def.fieldName, def]));
        this.selectedColumnFields.forEach((fieldName) => {
            const def = defByField.get(fieldName) || this.buildFallbackColumnDef(fieldName);
            if (!def) {
                return;
            }
            if (def.fieldName === 'Name') {
                columns.push({
                    label: def.label,
                    fieldName: 'recordUrl',
                    type: 'url',
                    sortable: true,
                    typeAttributes: { label: { fieldName: 'Name' }, target: '_self' }
                });
            } else {
                columns.push({
                    label: def.label,
                    fieldName: def.fieldName,
                    sortable: true,
                    type: def.type,
                    editable: !!def.editable
                });
            }
        });
        columns.push({
            type: 'action',
            fixedWidth: 88,
            typeAttributes: {
                rowActions: [{ label: 'View', name: 'view' }],
                menuAlignment: 'left'
            }
        });
        return columns;
    }

    handleSearchInput(event) {
        this.searchTerm = event.target.value;
        this.pageNumber = 1;
        clearTimeout(this.searchTimer);
        this.searchTimer = setTimeout(() => this.refreshData(), SEARCH_DEBOUNCE_MS);
    }

    async handleClearSearch() {
        this.searchTerm = '';
        this.pageNumber = 1;
        await this.refreshData();
    }

    async handleRefresh() {
        await this.refreshData();
    }

    async handleSort(event) {
        const { fieldName } = event.detail;
        const resolvedField = fieldName === 'recordUrl' ? 'Name' : fieldName;
        if (this.sortField === resolvedField) {
            this.sortDirection =
                String(this.sortDirection || 'ASC').toUpperCase() === 'DESC' ? 'ASC' : 'DESC';
        } else {
            this.sortField = resolvedField;
            this.sortDirection = 'ASC';
        }
        this.pageNumber = 1;
        await this.persistDisplayPreferences();
        await this.refreshData({ tableOnly: true });
    }

    async handlePreviousPage() {
        // removed - replaced by infinite scrolling
    }

    async handleListViewChange(event) {
        this.selectedListViewApiName = event.detail.value;
        this.pageNumber = 1;
        if (this.isCustomViewSelected) {
            this.applyCustomViewSelection();
        } else {
            this.applyDisplayPreferences(this.selectedListViewApiName);
        }
        await this.refreshData();
    }

    async handleFamilyFilterChange(event) {
        this.familyFilter = event.detail.value;
        await this.persistDisplayPreferences();
        await this.refreshData();
    }

    async handleActiveFilterChange(event) {
        this.activeFilter = event.detail.value;
        await this.persistDisplayPreferences();
        await this.refreshData();
    }

    handleOpenColumns() {
        this.showColumnModal = true;
    }

    handleCloseColumns() {
        this.showColumnModal = false;
    }

    handleColumnSelectionChange(event) {
        this.selectedColumnFields = event.detail.value;
    }

    async handleApplyColumns() {
        this.selectedColumnFields = this.enforceMandatoryColumns(this.selectedColumnFields);
        this.showColumnModal = false;
        try {
            const saved = await this.persistDisplayPreferences();
            if (saved?.selectedColumnFields?.length) {
                this.selectedColumnFields = [...saved.selectedColumnFields];
            }
            this.ensureColumnDefsForFields(this.selectedColumnFields);
            await this.refreshData();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Columns saved',
                    message: 'Display settings are saved for all users on this list view.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.handleError(error, { title: 'Error saving columns' });
        }
    }

    handleOpenCreateView() {
        this.newViewLabel = '';
        this.newViewFamilyFilter = this.familyFilter || '';
        this.newViewActiveFilter = this.activeFilter || 'all';
        this.showCreateViewModal = true;
    }

    handleCloseCreateView() {
        this.showCreateViewModal = false;
    }

    handleNewViewLabelChange(event) {
        this.newViewLabel = event.target.value;
    }

    handleNewViewFamilyFilterChange(event) {
        this.newViewFamilyFilter = event.detail.value;
    }

    handleNewViewActiveFilterChange(event) {
        this.newViewActiveFilter = event.detail.value;
    }

    async handleSaveView() {
        const label = (this.newViewLabel || '').trim();
        if (!label) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Missing Name',
                    message: 'Enter a list view name.',
                    variant: 'warning'
                })
            );
            return;
        }
        const viewId = `${Date.now()}`;
        const viewKey = `custom__${viewId}`;
        this.loading = true;
        try {
            const saved = await saveProductListViewDisplayConfig({
                viewKey,
                viewLabel: label,
                isCustom: true,
                selectedColumnFields: this.selectedColumnFields,
                familyFilter: this.newViewFamilyFilter || null,
                activeFilter: this.newViewActiveFilter || 'all',
                sortField: this.sortField,
                sortDirection: this.sortDirection
            });
            this.configByKey = { ...this.configByKey, [saved.viewKey]: saved };
            this.customViews = [
                ...this.customViews,
                {
                    id: viewId,
                    label,
                    selectedColumnFields: saved.selectedColumnFields || [],
                    familyFilter: saved.familyFilter || '',
                    activeFilter: saved.activeFilter || 'all',
                    sortField: saved.sortField || 'Name',
                    sortDirection: saved.sortDirection || 'ASC'
                }
            ];
            this.rebuildListViewOptions();
            this.selectedListViewApiName = viewKey;
            this.applyCustomViewSelection();
            this.showCreateViewModal = false;
            await this.refreshData();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'List View Created',
                    message: `"${label}" was saved for all users.`,
                    variant: 'success'
                })
            );
        } catch (error) {
            this.handleError(error, { title: 'Error creating list view' });
        } finally {
            this.loading = false;
        }
    }

    async handleDeleteCurrentView() {
        if (!this.isCustomViewSelected) {
            return;
        }
        const viewKey = this.selectedListViewApiName;
        this.loading = true;
        try {
            await deleteProductListViewDisplayConfig({ viewKey });
            const nextConfigByKey = { ...this.configByKey };
            delete nextConfigByKey[viewKey];
            this.configByKey = nextConfigByKey;
            this.customViews = this.customViews.filter(
                (view) => `custom__${view.id}` !== viewKey
            );
            this.selectedListViewApiName = this.baseListViewOptions[0].value;
            this.resetClientConfig();
            this.rebuildListViewOptions();
            await this.refreshData();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'List View Deleted',
                    message: 'The custom list view was removed for all users.',
                    variant: 'success'
                })
            );
        } catch (error) {
            this.handleError(error, { title: 'Error deleting list view' });
        } finally {
            this.loading = false;
        }
    }

    handleSettingsMenuSelect(event) {
        const action = event.detail.value;
        if (action === 'create') {
            this.handleOpenCreateView();
        } else if (action === 'columns') {
            this.handleOpenColumns();
        } else if (action === 'delete') {
            this.handleDeleteCurrentView();
        }
    }

    applyCustomViewSelection() {
        const id = this.selectedListViewApiName.replace('custom__', '');
        const view = this.customViews.find((item) => item.id === id);
        if (!view) {
            return;
        }
        this.selectedColumnFields = [...(view.selectedColumnFields || DEFAULT_COLUMN_FIELDS)];
        this.ensureColumnDefsForFields(this.selectedColumnFields);
        this.familyFilter = view.familyFilter || '';
        this.activeFilter = view.activeFilter || 'all';
        this.sortField = view.sortField || 'Name';
        this.sortDirection = view.sortDirection || 'ASC';
    }

    restoreViewPreferences() {
        if (this.isCustomViewSelected) {
            this.applyCustomViewSelection();
            return;
        }
        this.applyDisplayPreferences(this.selectedListViewApiName);
    }

    applyDisplayPreferences(listViewApiName) {
        const configKey = this.resolveConfigViewKey(listViewApiName);
        const prefs = this.configByKey[configKey] || this.configByKey[listViewApiName];
        if (prefs?.selectedColumnFields?.length) {
            this.selectedColumnFields = [...prefs.selectedColumnFields];
        } else {
            this.selectedColumnFields = [...DEFAULT_COLUMN_FIELDS];
        }
        this.ensureColumnDefsForFields(this.selectedColumnFields);
        this.familyFilter = prefs?.familyFilter ?? '';
        this.activeFilter = prefs?.activeFilter ?? 'all';
        this.sortField = prefs?.sortField ?? 'Name';
        this.sortDirection = prefs?.sortDirection ?? 'ASC';
    }

    resetClientConfig() {
        const defaultView = this.baseListViewOptions[0]?.value || 'AllProducts';
        this.applyDisplayPreferences(defaultView);
    }

    enforceMandatoryColumns(columnFields) {
        const fields = [];
        const seen = new Set();
        (columnFields || []).forEach((fieldName) => {
            if (!fieldName || seen.has(fieldName)) {
                return;
            }
            seen.add(fieldName);
            fields.push(fieldName);
        });
        if (!seen.has('Name')) {
            fields.unshift('Name');
            seen.add('Name');
        }
        if (!seen.has('ProductCode')) {
            const nameIndex = fields.indexOf('Name');
            const insertIndex = nameIndex >= 0 ? nameIndex + 1 : 0;
            fields.splice(insertIndex, 0, 'ProductCode');
        }
        return fields;
    }

    resolveConfigViewKey(listViewApiName) {
        const apiName = listViewApiName || ALL_PRODUCTS_VIEW_KEY;
        if (apiName === ALL_PRODUCTS_VIEW_KEY) {
            return ALL_PRODUCTS_VIEW_KEY;
        }
        const option = this.listViewOptions.find((row) => row.value === apiName);
        if (option?.label && option.label.trim().toLowerCase() === 'all products') {
            return ALL_PRODUCTS_VIEW_KEY;
        }
        return apiName;
    }

    resolveViewLabel(viewKey) {
        const option = this.listViewOptions.find((row) => row.value === viewKey);
        if (option?.label) {
            return option.label;
        }
        const custom = this.customViews.find((view) => `custom__${view.id}` === viewKey);
        return custom?.label || viewKey;
    }

    async persistDisplayPreferences() {
        const viewKey = this.resolveConfigViewKey(this.selectedListViewApiName || ALL_PRODUCTS_VIEW_KEY);
        const saved = await saveProductListViewDisplayConfig({
            viewKey,
            viewLabel: this.resolveViewLabel(viewKey),
            isCustom: this.isCustomViewSelected,
            selectedColumnFields: this.selectedColumnFields,
            familyFilter: this.familyFilter || null,
            activeFilter: this.activeFilter || 'all',
            sortField: this.sortField,
            sortDirection: this.sortDirection
        });
        this.configByKey = { ...this.configByKey, [saved.viewKey]: saved };
        if (this.isCustomViewSelected) {
            const id = viewKey.replace('custom__', '');
            this.customViews = this.customViews.map((view) => {
                if (view.id !== id) {
                    return view;
                }
                return {
                    ...view,
                    label: saved.viewLabel || view.label,
                    selectedColumnFields: saved.selectedColumnFields || [],
                    familyFilter: saved.familyFilter || '',
                    activeFilter: saved.activeFilter || 'all',
                    sortField: saved.sortField || 'Name',
                    sortDirection: saved.sortDirection || 'ASC'
                };
            });
        }
        return saved;
    }

    async refreshData(options = {}) {
        const tableOnly = options.tableOnly === true;
        if (tableOnly) {
            this.isTableRefreshing = true;
        } else {
            this.loading = true;
        }
        try {
            await this.loadProducts();
        } catch (error) {
            this.handleError(error);
        } finally {
            if (tableOnly) {
                this.isTableRefreshing = false;
            } else {
                this.loading = false;
            }
        }
    }

    async handleLoadMore(event) {
        if (this.isLoadingMore || this.loading || !this.hasMore) {
            return;
        }
        this.isLoadingMore = true;
        const datatable = event?.target;
        if (datatable) {
            datatable.isLoading = true;
        }
        try {
            await this.loadMoreProducts(true);
        } catch (error) {
            this.handleError(error, { clearRows: false });
        } finally {
            this.isLoadingMore = false;
            if (datatable) {
                datatable.isLoading = false;
            }
        }
    }

    async handleSaveEdits(event) {
        const draftValues = event.detail?.draftValues || [];
        if (!draftValues.length) {
            return;
        }
        this.loading = true;
        this.tableErrors = undefined;
        try {
            const result = await updateProductsForListView({ draftValues });
            const errors = result?.errors || [];
            const failedIds = new Set(errors.filter((item) => item?.recordId).map((item) => item.recordId));
            this.applySuccessfulDrafts(draftValues, failedIds);
            this.draftValues = draftValues.filter((item) => failedIds.has(item.Id));
            if (errors.length) {
                this.tableErrors = this.buildTableErrors(errors);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Some updates failed',
                        message: `${result?.successCount || 0} records saved, ${errors.length} failed.`,
                        variant: 'warning'
                    })
                );
            } else {
                this.draftValues = [];
                this.tableErrors = undefined;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Products updated',
                        message: `${result?.successCount || 0} records updated successfully.`,
                        variant: 'success'
                    })
                );
            }
        } catch (error) {
            this.handleError(error, { clearRows: false, title: 'Error updating products' });
        } finally {
            this.loading = false;
        }
    }

    handleRowAction(event) {
        const actionName = event.detail.action.name;
        const row = event.detail.row;
        if ((actionName === 'view' || actionName === 'open') && row.Id) {
            this.navigateToRecord(row.Id);
        }
    }

    handleNewProduct() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: OBJECT_API_NAME,
                actionName: 'new'
            }
        });
    }

    mapApexRows(records) {
        return (records || []).map((record) => {
            const row = { Id: record.id, recordUrl: `/${record.id}` };
            const fields = record.fields || {};
            Object.keys(fields).forEach((fieldApiName) => {
                row[fieldApiName] = fields[fieldApiName];
            });
            if (!row.Name) {
                row.Name = '';
            }
            return row;
        });
    }

    toLabel(apiName) {
        return String(apiName)
            .replace(/__c$/, '')
            .replace(/_/g, ' ')
            .replace(/([a-z])([A-Z])/g, '$1 $2');
    }

    buildFallbackColumnDef(fieldName) {
        if (!fieldName) {
            return null;
        }
        const known = COLUMN_DEFS.find((def) => def.fieldName === fieldName);
        if (known) {
            return { ...known };
        }
        return {
            fieldName,
            label: this.toLabel(fieldName),
            type: 'text',
            editable: INLINE_EDITABLE_FIELDS.has(fieldName)
        };
    }

    ensureColumnDefsForFields(fieldNames) {
        (fieldNames || []).forEach((fieldName) => {
            if (!fieldName || this.columnDefByField.has(fieldName)) {
                return;
            }
            const fallback = this.buildFallbackColumnDef(fieldName);
            if (fallback) {
                this.columnDefByField.set(fieldName, fallback);
            }
        });
    }

    navigateToRecord(recordId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: OBJECT_API_NAME,
                actionName: 'view'
            }
        });
    }

    applySuccessfulDrafts(draftValues, failedIds) {
        const successDrafts = draftValues.filter((item) => !failedIds.has(item.Id));
        if (!successDrafts.length) {
            return;
        }
        const updatesById = new Map(successDrafts.map((item) => [item.Id, item]));
        this.rawRows = this.rawRows.map((row) => {
            const draft = updatesById.get(row.Id);
            if (!draft) {
                return row;
            }
            return { ...row, ...draft };
        });
        this.applyClientFilters();
    }

    buildTableErrors(errors) {
        const rows = {};
        (errors || []).forEach((error) => {
            if (!error?.recordId) {
                return;
            }
            rows[error.recordId] = {
                title: 'Update failed',
                messages: [error.message || 'Unable to update this row.'],
                fieldNames: error.fieldNames || []
            };
        });
        return { rows };
    }

    handleError(error, options = {}) {
        const { clearRows = true } = options;
        const title = options.title || 'Error loading products';
        this.errorMessage = this.reduceErrors(error);
        if (clearRows) {
            this.tableRows = [];
        }
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message: this.errorMessage,
                variant: 'error'
            })
        );
    }

    reduceErrors(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (typeof error.body?.message === 'string') {
            return error.body.message;
        }
        if (typeof error.message === 'string') {
            return error.message;
        }
        return 'Unknown error';
    }
}