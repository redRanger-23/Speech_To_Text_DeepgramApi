import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import transcribeAndSaveNote from '@salesforce/apex/AudioNoteController.transcribeAndSaveNote';
import saveAudioFile from '@salesforce/apex/AudioNoteController.saveAudioFile';

// Steps
const STEP_RECORD  = 'record';
const STEP_PREVIEW = 'preview';
const STEP_SUCCESS = 'success';

// Max recording duration (10 minutes in ms)
const MAX_RECORDING_MS = 10 * 60 * 1000;

export default class AudioNoteRecorder extends LightningElement {

    @api recordId;

    // ─── State ───────────────────────────────────────────────────────────────

    @track step              = STEP_RECORD;
    @track isRecording       = false;
    @track isTranscribing    = false;
    @track isSaving          = false;
    @track transcriptionText = '';
    @track transcriptionError = '';
    @track recordingDuration  = '00:00';

    // Private
    _mediaRecorder   = null;
    _audioChunks     = [];
    _audioBlob       = null;
    _audioBase64     = null;
    _durationInterval = null;
    _durationSeconds  = 0;
    _maxRecordingTimer = null;

    // ─── Step Getters ─────────────────────────────────────────────────────────

    get isStepRecord()  { return this.step === STEP_RECORD; }
    get isStepPreview() { return this.step === STEP_PREVIEW; }
    get isStepSuccess() { return this.step === STEP_SUCCESS; }

    // ─── UI Getters ───────────────────────────────────────────────────────────

    get recordingStatusLabel() {
        if (this.isTranscribing) return 'Transcribing…';
        return this.isRecording ? 'Recording in progress…' : 'Ready to record';
    }

    get recordingIndicatorClass() {
        return this.isRecording
            ? 'recording-indicator recording-indicator--active slds-align_absolute-center'
            : 'recording-indicator slds-align_absolute-center';
    }

    get recordingIconClass() {
        return this.isRecording ? 'recording-icon--pulsing' : '';
    }

    // ─── Recording ────────────────────────────────────────────────────────────

    async startRecording() {
        this.transcriptionError = '';
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });

            // Prefer webm/opus; fall back to whatever the browser supports
            const mimeType = this._getSupportedMimeType();
            const options  = mimeType ? { mimeType } : {};

            this._mediaRecorder = new MediaRecorder(stream, options);
            this._audioChunks   = [];

            this._mediaRecorder.addEventListener('dataavailable', e => {
                if (e.data.size > 0) this._audioChunks.push(e.data);
            });

            this._mediaRecorder.addEventListener('stop', () => {
                this._onRecordingStop(mimeType || 'audio/webm');
                // Release microphone
                stream.getTracks().forEach(t => t.stop());
            });

            this._mediaRecorder.start(1000); // collect data every second
            this.isRecording = true;
            this._startDurationTimer();

            // Auto-stop after max duration
            this._maxRecordingTimer = setTimeout(() => {
                if (this.isRecording) this.stopRecording();
            }, MAX_RECORDING_MS);

        } catch (err) {
            console.error('Microphone access error:', err);
            this._showToast('Microphone Error',
                'Could not access your microphone. Please check browser permissions.', 'error');
        }
    }

    stopRecording() {
        if (this._mediaRecorder && this.isRecording) {
            this._mediaRecorder.stop();
            this.isRecording = false;
            this._stopDurationTimer();
            clearTimeout(this._maxRecordingTimer);
        }
    }

    _getSupportedMimeType() {
        const types = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
        return types.find(t => MediaRecorder.isTypeSupported(t)) || '';
    }

    async _onRecordingStop(mimeType) {
        this._audioBlob   = new Blob(this._audioChunks, { type: mimeType });
        this._audioBase64 = await this._blobToBase64(this._audioBlob);
        await this._transcribeAudio();
    }

    // ─── Transcription ────────────────────────────────────────────────────────

    async _transcribeAudio() {
        this.isTranscribing = true;
        try {
            const result = await transcribeAndSaveNote({
                recordId      : this.recordId,
                audioBase64   : this._audioBase64,
                audioMimeType : this._audioBlob.type
            });

            if (result.success) {
                this.transcriptionText = result.transcription;
                this.step = STEP_PREVIEW;
            } else {
                this.transcriptionError = result.errorMessage || 'Transcription failed. You can save the audio file only.';
            }
        } catch (err) {
            console.error('Transcription error:', err);
            this.transcriptionError = 'Transcription service unavailable. You can save the audio file only.';
        } finally {
            this.isTranscribing = false;
        }
    }

    // ─── Preview / Edit ───────────────────────────────────────────────────────

    handleTranscriptionChange(event) {
        this.transcriptionText = event.detail.value;
    }

    // ─── Confirm & Save ───────────────────────────────────────────────────────

    async handleConfirmSave() {
        if (!this.transcriptionText || !this.transcriptionText.trim()) {
            this._showToast('Validation', 'Transcription cannot be empty.', 'warning');
            return;
        }

        this.isSaving = true;
        try {
            await transcribeAndSaveNote({
                recordId        : this.recordId,
                audioBase64     : this._audioBase64,
                audioMimeType   : this._audioBlob ? this._audioBlob.type : '',
                confirmedText   : this.transcriptionText,
                saveMode        : true
            });
            this.step = STEP_SUCCESS;
        } catch (err) {
            console.error('Save error:', err);
            this._showToast('Save Failed', 'Could not save the note. Please try again.', 'error');
        } finally {
            this.isSaving = false;
        }
    }

    async saveAudioOnly() {
        try {
            await saveAudioFile({
                recordId      : this.recordId,
                audioBase64   : this._audioBase64,
                audioMimeType : this._audioBlob ? this._audioBlob.type : 'audio/webm'
            });
            this._showToast('Audio Saved', 'Audio file saved successfully (no transcription).', 'success');
            this.resetRecorder();
        } catch (err) {
            console.error('Audio save error:', err);
            this._showToast('Save Failed', 'Could not save audio file.', 'error');
        }
    }

    // ─── Cancel / Reset ───────────────────────────────────────────────────────

    handleCancel() {
        // Discard everything without saving
        this.resetRecorder();
    }

    resetRecorder() {
        this.step              = STEP_RECORD;
        this.isRecording       = false;
        this.isTranscribing    = false;
        this.isSaving          = false;
        this.transcriptionText = '';
        this.transcriptionError = '';
        this.recordingDuration  = '00:00';
        this._audioChunks      = [];
        this._audioBlob        = null;
        this._audioBase64      = null;
        this._durationSeconds  = 0;
        this._stopDurationTimer();
        clearTimeout(this._maxRecordingTimer);
    }

    // ─── Duration Timer ───────────────────────────────────────────────────────

    _startDurationTimer() {
        this._durationSeconds = 0;
        this._durationInterval = setInterval(() => {
            this._durationSeconds++;
            const m = String(Math.floor(this._durationSeconds / 60)).padStart(2, '0');
            const s = String(this._durationSeconds % 60).padStart(2, '0');
            this.recordingDuration = `${m}:${s}`;
        }, 1000);
    }

    _stopDurationTimer() {
        if (this._durationInterval) {
            clearInterval(this._durationInterval);
            this._durationInterval = null;
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    _blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onloadend = () => {
                // Strip data URL prefix: "data:audio/webm;base64,"
                const base64 = reader.result.split(',')[1];
                resolve(base64);
            };
            reader.onerror = reject;
            reader.readAsDataURL(blob);
        });
    }

    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // Cleanup on component destroy
    disconnectedCallback() {
        this.resetRecorder();
    }
}