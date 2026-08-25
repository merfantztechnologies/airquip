import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import FORM_FACTOR from '@salesforce/client/formFactor';
import CASE_SUBJECT from '@salesforce/schema/Case.Subject';
import ACCOUNT_NAME from '@salesforce/schema/Account.Name';
import CONTACT_NAME from '@salesforce/schema/Contact.Name';
import LEAD_COMPANY from '@salesforce/schema/Lead.Company';
import OPPORTUNITY_NAME from '@salesforce/schema/Opportunity.Name';
import JOB_VISIT_TYPE from '@salesforce/schema/fax__Job__c.fax__Visit_Type__c';
import JOB_VISIT_DESCRIPTION from '@salesforce/schema/fax__Job__c.fax__Visit_Description__c';
import getKnowledgeForRecord from '@salesforce/apex/KnowledgeSuggestionController.getKnowledgeForRecord';
import getArticlePreview from '@salesforce/apex/KnowledgeSuggestionController.getArticlePreview';
import attachArticle from '@salesforce/apex/KnowledgeSuggestionController.attachArticle';
import createArticle from '@salesforce/apex/KnowledgeSuggestionController.createArticle';

const RECORD_FIELDS_BY_OBJECT = {
    Case: [CASE_SUBJECT],
    Account: [ACCOUNT_NAME],
    Contact: [CONTACT_NAME],
    Lead: [LEAD_COMPANY],
    Opportunity: [OPPORTUNITY_NAME],
    fax__Job__c: [JOB_VISIT_TYPE, JOB_VISIT_DESCRIPTION]
};

export default class KnowledgeSuggestions extends NavigationMixin(LightningElement) {
    @api searchFieldApiName;
    @api descriptionFieldApiName;

    _recordId;
    pageRecordId;
    objectApiName;
    lastLoadedRecordId;
    lastLoadedSearchKey = '';
    trackedSearchValue = '';
    hoveredArticleId;
    previewData;
    previewLoading = false;
    previewTop = 0;
    previewLeft = 0;
    hoverHideTimeout;

    articles = [];
    recordSearchText = '';
    knowledgeSearchTerm = '';
    objectLabel = '';
    errorMessage;
    previewErrorMessage;
    isLoading = true;
    showNewArticleModal = false;
    isSavingArticle = false;
    newArticleStep = 'details';
    createdArticleId;
    uploadedFileCount = 0;
    newArticleTitle = '';
    newArticleUrlName = '';
    newArticleBody = '';
    newArticleStatus = 'Draft';
    newArticleVisibleInApp = false;
    urlNameManuallyEdited = false;
    newArticleErrorMessage;
    loadRequestId = 0;
    previewRequestId = 0;

    disconnectedCallback() {
        clearTimeout(this.hoverHideTimeout);
    }

    isValidSalesforceId(value) {
        return typeof value === 'string' && /^[a-zA-Z0-9]{15,18}$/.test(value);
    }

    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.loadArticles(true);
        }
    }

    @wire(CurrentPageReference)
    handlePageReference(pageRef) {
        const pageRecordId = pageRef?.attributes?.recordId;
        const objectApiName = pageRef?.attributes?.objectApiName;

        if (objectApiName) {
            this.objectApiName = objectApiName;
        }

        if (pageRecordId) {
            this.pageRecordId = pageRecordId;
            if (!this._recordId) {
                this.loadArticles(true);
            }
        }
    }

    get effectiveRecordId() {
        return this._recordId || this.pageRecordId;
    }

    get wiredRecordFields() {
        if (this.objectApiName && RECORD_FIELDS_BY_OBJECT[this.objectApiName]) {
            return RECORD_FIELDS_BY_OBJECT[this.objectApiName];
        }
        return RECORD_FIELDS_BY_OBJECT.Case;
    }

    @wire(getRecord, { recordId: '$effectiveRecordId', fields: '$wiredRecordFields' })
    handleRecordFieldChange({ data }) {
        if (!data || this.wiredRecordFields.length === 0) {
            return;
        }

        const searchValue = getFieldValue(data, this.wiredRecordFields[0]) || '';
        if (searchValue === this.trackedSearchValue) {
            return;
        }

        this.trackedSearchValue = searchValue;
        this.lastLoadedRecordId = null;
        this.lastLoadedSearchKey = '';
        this.loadArticles(true);
    }

    get attachedArticles() {
        return this.filterByKnowledgeSearch(
            this.articles.filter((article) => article.isAttached)
        );
    }

    get suggestedArticles() {
        return this.filterByKnowledgeSearch(
            this.articles.filter((article) => !article.isAttached)
        );
    }

    get hasAttachedArticles() {
        return this.attachedArticles.length > 0;
    }

    get hasSuggestedArticles() {
        return this.suggestedArticles.length > 0;
    }

    get hasAnyArticles() {
        return this.attachedArticles.length > 0 || this.suggestedArticles.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading && !this.hasAnyArticles && !this.errorMessage;
    }

    get showPreviewPanel() {
        return this.previewData || this.previewLoading;
    }

    get isMobile() {
        return FORM_FACTOR === 'Small';
    }

    get knowledgePanelClass() {
        return this.isMobile ? 'knowledge-panel knowledge-panel--mobile' : 'knowledge-panel';
    }

    get newArticleModalClass() {
        const baseClass = 'slds-modal slds-fade-in-open new-article-modal';
        return this.isMobile ? `${baseClass} slds-modal_full` : baseClass;
    }

    get previewPanelClass() {
        return this.isMobile
            ? 'article-preview-panel article-preview-panel--mobile'
            : 'article-preview-panel';
    }

    get previewPanelStyle() {
        if (this.isMobile) {
            return '';
        }
        return `top: ${this.previewTop}px; left: ${this.previewLeft}px;`;
    }

    get suggestedResultLabel() {
        const count = this.suggestedArticles.length;
        if (count === 1) {
            return '1 Result';
        }
        return `${count} Results`;
    }

    get emptyStateMessage() {
        if (!this.effectiveRecordId) {
            return 'Unable to load the current record. Refresh the page and try again.';
        }
        if (this.knowledgeSearchTerm) {
            return `No articles matched "${this.knowledgeSearchTerm}".`;
        }
        if (!this.recordSearchText) {
            return 'No published knowledge articles are available. Add a subject to this record for better suggestions.';
        }
        return `No published knowledge articles matched "${this.recordSearchText}".`;
    }

    filterByKnowledgeSearch(articles) {
        const term = (this.knowledgeSearchTerm || '').trim().toLowerCase();
        if (!term) {
            return articles;
        }

        return articles.filter((article) => {
            const title = (article.title || '').toLowerCase();
            const excerpt = (article.excerpt || '').toLowerCase();
            const urlName = (article.urlName || '').toLowerCase();
            return title.includes(term) || excerpt.includes(term) || urlName.includes(term);
        });
    }

    handleKnowledgeSearchChange(event) {
        this.knowledgeSearchTerm = event.target.value || '';
    }

    updatePreviewPosition(element) {
        const rect = element.getBoundingClientRect();
        const panelWidth = 416;
        const viewportPadding = 12;
        const estimatedHalfHeight = Math.min(window.innerHeight * 0.35, 280);

        let left = rect.right + viewportPadding;
        let top = rect.top + rect.height / 2;

        if (left + panelWidth > window.innerWidth - viewportPadding) {
            left = Math.max(viewportPadding, window.innerWidth - panelWidth - viewportPadding);
        }

        if (top - estimatedHalfHeight < viewportPadding) {
            top = estimatedHalfHeight + viewportPadding;
        }

        if (top + estimatedHalfHeight > window.innerHeight - viewportPadding) {
            top = window.innerHeight - estimatedHalfHeight - viewportPadding;
        }

        this.previewTop = top;
        this.previewLeft = left;
    }

    async handlePreviewShow(event) {
        if (this.isMobile) {
            return;
        }
        await this.loadPreviewForArticle(event.currentTarget.dataset.id, event.currentTarget);
    }

    async showPreviewForArticle(articleId, anchorElement) {
        clearTimeout(this.hoverHideTimeout);

        if (!this.isValidSalesforceId(articleId)) {
            return;
        }

        this.hoveredArticleId = articleId;
        if (anchorElement) {
            this.updatePreviewPosition(anchorElement);
        }

        if (this.previewData?.id === articleId && this.showPreviewPanel) {
            if (this.isMobile) {
                this.closePreview();
            }
            return;
        }

        await this.loadPreviewForArticle(articleId, anchorElement);
    }

    async loadPreviewForArticle(articleId, anchorElement) {
        if (!this.isValidSalesforceId(articleId)) {
            return;
        }

        if (anchorElement && !this.isMobile) {
            this.updatePreviewPosition(anchorElement);
        }

        const requestId = ++this.previewRequestId;
        this.previewLoading = true;
        this.previewData = null;
        this.previewErrorMessage = undefined;

        try {
            const preview = await getArticlePreview({ articleId });
            if (requestId !== this.previewRequestId) {
                return;
            }
            this.previewData = preview;
        } catch (error) {
            if (requestId !== this.previewRequestId) {
                return;
            }
            this.previewErrorMessage = this.reduceError(
                error,
                'Unable to load article preview.'
            );
        } finally {
            if (requestId === this.previewRequestId) {
                this.previewLoading = false;
            }
        }
    }

    closePreview() {
        clearTimeout(this.hoverHideTimeout);
        this.hoveredArticleId = null;
        this.previewData = null;
        this.previewLoading = false;
        this.previewErrorMessage = undefined;
        this.previewRequestId += 1;
    }

    handlePreviewHide() {
        if (this.isMobile) {
            return;
        }
        this.hoverHideTimeout = setTimeout(() => {
            this.closePreview();
        }, 250);
    }

    handlePreviewPanelEnter() {
        clearTimeout(this.hoverHideTimeout);
    }

    async loadArticles(forceReload = false) {
        const recordId = this.effectiveRecordId;
        if (!recordId) {
            this.isLoading = false;
            return;
        }

        const searchKey = this.trackedSearchValue || this.recordSearchText || '';
        if (!forceReload && recordId === this.lastLoadedRecordId && searchKey === this.lastLoadedSearchKey) {
            return;
        }

        const requestId = ++this.loadRequestId;
        this.isLoading = true;

        try {
            const data = await getKnowledgeForRecord({
                recordId,
                searchFieldOverride: this.searchFieldApiName || null,
                descriptionFieldOverride: this.descriptionFieldApiName || null
            });

            if (requestId !== this.loadRequestId) {
                return;
            }

            this.lastLoadedRecordId = recordId;
            this.lastLoadedSearchKey = data?.searchText || searchKey;
            this.trackedSearchValue = data?.searchText || this.trackedSearchValue;
            this.articles = data?.articles || [];
            this.recordSearchText = data?.searchText || '';
            this.objectLabel = data?.objectLabel || '';
            this.errorMessage = undefined;
        } catch (error) {
            if (requestId !== this.loadRequestId) {
                return;
            }
            this.articles = [];
            this.recordSearchText = '';
            this.objectLabel = '';
            this.errorMessage = this.reduceError(
                error,
                'Unable to load knowledge articles.'
            );
        } finally {
            if (requestId === this.loadRequestId) {
                this.isLoading = false;
            }
        }
    }

    async handleMenuSelect(event) {
        const articleId = event.currentTarget.dataset.id;
        const action = event.detail.value;

        if (!this.isValidSalesforceId(articleId)) {
            this.errorMessage = 'Invalid article selected.';
            return;
        }

        if (action === 'open') {
            this.navigateToArticle(articleId);
            return;
        }

        if (action === 'preview') {
            const row = event.currentTarget.closest('.article-item');
            const anchor = row ? row.querySelector('.article-title') : null;
            await this.showPreviewForArticle(articleId, anchor);
            return;
        }

        if (action === 'attach') {
            await this.attachArticleById(articleId);
        }
    }

    async attachArticleById(articleId) {
        const recordId = this.effectiveRecordId;
        if (!recordId) {
            this.errorMessage = 'Unable to attach articles because the record Id is missing.';
            return;
        }
        if (!this.isValidSalesforceId(articleId)) {
            this.errorMessage = 'Invalid article selected.';
            return;
        }

        this.isLoading = true;

        try {
            await attachArticle({ recordId, articleId });
            this.lastLoadedRecordId = null;
            this.lastLoadedSearchKey = '';
            await this.loadArticles(true);
        } catch (error) {
            this.errorMessage = this.reduceError(
                error,
                'Unable to attach the selected article.'
            );
        } finally {
            this.isLoading = false;
        }
    }

    handleArticleTitleClick(event) {
        const articleId = event.currentTarget.dataset.id;
        if (this.isMobile) {
            this.showPreviewForArticle(articleId, null);
            return;
        }
        this.navigateToArticle(articleId);
    }

    handleOpenArticle(event) {
        this.handleArticleTitleClick(event);
    }

    handleOpenPreviewArticle() {
        if (this.previewData?.id) {
            this.navigateToArticle(this.previewData.id);
        }
    }

    get richTextFormats() {
        return [
            'bold',
            'italic',
            'underline',
            'strike',
            'list',
            'indent',
            'align',
            'link',
            'image',
            'clean',
            'header',
            'color',
            'background',
            'font',
            'size',
            'table'
        ];
    }

    get statusOptions() {
        return [
            { label: 'Draft', value: 'Draft' },
            { label: 'Review', value: 'Review' },
            { label: 'Published', value: 'Published' },
            { label: 'Archived', value: 'Archived' }
        ];
    }

    get titleCharacterCount() {
        return `${(this.newArticleTitle || '').length}/80`;
    }

    get isNewArticleDetailsStep() {
        return this.newArticleStep === 'details';
    }

    get isNewArticleFilesStep() {
        return this.newArticleStep === 'files';
    }

    get newArticleModalTitle() {
        return this.isNewArticleFilesStep ? 'Attach Files' : 'New Knowledge Article';
    }

    get uploadedFileLabel() {
        if (this.uploadedFileCount === 1) {
            return '1 file uploaded';
        }
        return `${this.uploadedFileCount} files uploaded`;
    }

    resetNewArticleState() {
        this.newArticleStep = 'details';
        this.createdArticleId = undefined;
        this.uploadedFileCount = 0;
        this.newArticleTitle = '';
        this.newArticleUrlName = '';
        this.newArticleBody = '';
        this.newArticleStatus = 'Draft';
        this.newArticleVisibleInApp = false;
        this.urlNameManuallyEdited = false;
        this.isSavingArticle = false;
        this.newArticleErrorMessage = undefined;
    }

    clearNewArticleFieldValidity() {
        const titleInput = this.template.querySelector('[data-field="article-title"]');
        const urlInput = this.template.querySelector('[data-field="article-url-name"]');

        if (titleInput) {
            titleInput.setCustomValidity('');
        }
        if (urlInput) {
            urlInput.setCustomValidity('');
        }
    }

    validateNewArticleForm() {
        this.newArticleErrorMessage = undefined;

        const titleInput = this.template.querySelector('[data-field="article-title"]');
        const urlInput = this.template.querySelector('[data-field="article-url-name"]');
        const title = (this.newArticleTitle || '').trim();
        const urlName = (this.newArticleUrlName || '').trim() || this.buildUrlName(title);
        let isValid = true;

        if (titleInput) {
            titleInput.setCustomValidity('');
            if (!title) {
                titleInput.setCustomValidity('Complete this field.');
                isValid = false;
            }
            titleInput.reportValidity();
        }

        if (urlInput) {
            urlInput.setCustomValidity('');
            if (!urlName) {
                urlInput.setCustomValidity('Complete this field.');
                isValid = false;
            }
            urlInput.reportValidity();
        }

        if (!isValid) {
            this.newArticleErrorMessage = 'Review the required fields below.';
        }

        return isValid;
    }

    handleNewArticle() {
        this.resetNewArticleState();
        this.errorMessage = undefined;
        this.showNewArticleModal = true;
    }

    handleCloseNewArticleModal() {
        this.showNewArticleModal = false;
        this.resetNewArticleState();
    }

    handleFinishNewArticle(openArticle) {
        const articleId = this.createdArticleId;
        this.showNewArticleModal = false;
        this.resetNewArticleState();

        if (openArticle && articleId) {
            this.navigateToArticle(articleId);
        }
    }

    handleNewArticleTitleChange(event) {
        this.newArticleTitle = event.target.value || '';
        event.target.setCustomValidity('');
        this.newArticleErrorMessage = undefined;
        if (!this.urlNameManuallyEdited) {
            this.newArticleUrlName = this.buildUrlName(this.newArticleTitle);
        }
    }

    handleNewArticleUrlNameChange(event) {
        this.newArticleUrlName = event.target.value || '';
        this.urlNameManuallyEdited = true;
        event.target.setCustomValidity('');
        this.newArticleErrorMessage = undefined;
    }

    handleNewArticleBodyChange(event) {
        this.newArticleBody = event.detail.value || '';
    }

    handleNewArticleStatusChange(event) {
        this.newArticleStatus = event.detail.value;
    }

    handleNewArticleVisibleChange(event) {
        this.newArticleVisibleInApp = event.target.checked;
    }

    handleUploadFinished(event) {
        try {
            const uploadedFiles = event?.detail?.files || [];
            this.uploadedFileCount += uploadedFiles.length;
        } catch (error) {
            this.newArticleErrorMessage = this.reduceError(
                error,
                'Unable to process uploaded files.'
            );
        }
    }

    handleSkipFiles() {
        this.handleFinishNewArticle(false);
    }

    handleOpenCreatedArticle() {
        this.handleFinishNewArticle(true);
    }

    buildUrlName(title) {
        const slug = (title || '')
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, '-')
            .replace(/^-+|-+$/g, '');
        return slug.substring(0, 80).replace(/-+$/, '');
    }

    async handleSaveNewArticle() {
        if (!this.validateNewArticleForm()) {
            return;
        }

        const title = (this.newArticleTitle || '').trim();
        const urlName = (this.newArticleUrlName || '').trim() || this.buildUrlName(title);

        this.isSavingArticle = true;
        this.newArticleErrorMessage = undefined;

        try {
            const articleId = await createArticle({
                name: title.substring(0, 80),
                urlName,
                articleBody: this.newArticleBody,
                status: this.newArticleStatus,
                isVisibleInApp: this.newArticleVisibleInApp
            });

            this.createdArticleId = articleId;
            this.newArticleStep = 'files';
            this.uploadedFileCount = 0;
            this.lastLoadedRecordId = null;
            this.lastLoadedSearchKey = '';
            await this.loadArticles(true);
        } catch (error) {
            this.newArticleErrorMessage = this.reduceError(
                error,
                'Unable to save the knowledge article.'
            );
        } finally {
            this.isSavingArticle = false;
        }
    }

    navigateToArticle(articleId) {
        if (!this.isValidSalesforceId(articleId)) {
            this.errorMessage = 'Unable to open the selected article.';
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: articleId,
                objectApiName: 'Knowledge_Article__c',
                actionName: 'view'
            }
        });
    }

    reduceError(error, fallbackMessage) {
        if (Array.isArray(error?.body)) {
            return error.body.map((item) => item.message).join(', ');
        }

        if (Array.isArray(error?.body?.pageErrors) && error.body.pageErrors.length > 0) {
            return error.body.pageErrors.map((item) => item.message).join(', ');
        }

        if (error?.body?.output?.errors?.length) {
            return error.body.output.errors.map((item) => item.message).join(', ');
        }

        if (error?.body?.fieldErrors) {
            const fieldMessages = [];
            Object.keys(error.body.fieldErrors).forEach((fieldName) => {
                error.body.fieldErrors[fieldName].forEach((fieldError) => {
                    fieldMessages.push(fieldError.message);
                });
            });
            if (fieldMessages.length > 0) {
                return fieldMessages.join(', ');
            }
        }

        return error?.body?.message || error?.message || fallbackMessage;
    }
}