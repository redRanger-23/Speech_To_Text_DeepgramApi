/**
 * AudioNoteController
 *
 * Handles:
 *  1. Sending audio to Deepgram for transcription with speaker diarization
 *  2. Saving the transcript to Contact.DeepGram_Transcript__c
 *  3. Saving the raw audio as a ContentVersion (File) linked to the Contact
 *
 * Prerequisites:
 *  - Named Credential: "Deepgram_API" pointing to https://api.deepgram.com
 *    with HTTP Header: "Authorization: Token <YOUR_API_KEY>"
 *  - Custom field: Contact.DeepGram_Transcript__c (Long Text Area recommended)
 */
public with sharing class AudioNoteController {

    // ─── Response Wrapper ─────────────────────────────────────────────────────

    public class TranscribeResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  transcription;
        @AuraEnabled public String  errorMessage;

        public TranscribeResult(Boolean success, String transcription, String errorMessage) {
            this.success       = success;
            this.transcription = transcription;
            this.errorMessage  = errorMessage;
        }
    }

    // ─── Main Method ──────────────────────────────────────────────────────────

    @AuraEnabled
    public static TranscribeResult transcribeAndSaveNote(
        String  recordId,
        String  audioBase64,
        String  audioMimeType,
        String  confirmedText,
        Boolean saveMode
    ) {
        try {
            if (saveMode == true) {
                saveTranscriptToContact(recordId, confirmedText);
                if (String.isNotBlank(audioBase64)) {
                    saveAudioFile(recordId, audioBase64, audioMimeType);
                }
                return new TranscribeResult(true, confirmedText, null);

            } else {
                String transcription = callDeepgram(audioBase64, audioMimeType);
                return new TranscribeResult(true, transcription, null);
            }

        } catch (Exception e) {
            System.debug('AudioNoteController ERROR: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return new TranscribeResult(false, null, e.getMessage());
        }
    }

    // ─── Save Transcript to Contact Field ────────────────────────────────────

    private static void saveTranscriptToContact(String recordId, String transcriptText) {
        if (String.isBlank(recordId)) {
            throw new AuraHandledException('Record Id is required to save the transcript.');
        }
        if (String.isBlank(transcriptText)) {
            throw new AuraHandledException('Transcript text is empty — nothing to save.');
        }

        Contact c = new Contact(
            Id                     = recordId,
            DeepGram_Transcript__c = transcriptText
        );
        update c;

        System.debug('AudioNoteController: transcript saved to Contact ' + recordId);
    }

    // ─── Save Audio File ──────────────────────────────────────────────────────

    @AuraEnabled
    public static void saveAudioFile(String recordId, String audioBase64, String audioMimeType) {
        try {
            Blob   audioBlob = EncodingUtil.base64Decode(audioBase64);
            String extension = getExtension(audioMimeType);
            String fileName  = 'AudioNote_' + Datetime.now().format('yyyyMMdd_HHmmss') + '.' + extension;

            ContentVersion cv = new ContentVersion();
            cv.Title                  = fileName;
            cv.PathOnClient           = fileName;
            cv.VersionData            = audioBlob;
            cv.FirstPublishLocationId = recordId;
            insert cv;

            System.debug('AudioNoteController: audio file saved — ' + fileName);

        } catch (Exception e) {
            throw new AuraHandledException('Failed to save audio file: ' + e.getMessage());
        }
    }

    // ─── Deepgram Callout ─────────────────────────────────────────────────────

    private static String callDeepgram(String audioBase64, String audioMimeType) {
        if (String.isBlank(audioBase64)) {
            throw new AuraHandledException('No audio data received for transcription.');
        }

        Blob    audioBlob = EncodingUtil.base64Decode(audioBase64);
        Integer blobSize  = audioBlob.size();
        System.debug('AudioNoteController: audio size = ' + blobSize + ' bytes | mimeType = ' + audioMimeType);

        if (blobSize > 11534336) {
            throw new AuraHandledException(
                'Recording is too large (' + (blobSize / 1048576) + ' MB). Please keep recordings under 8 minutes.'
            );
        }

        String mimeType = String.isBlank(audioMimeType) ? 'audio/webm' : audioMimeType;
        if (mimeType.contains(';')) {
            mimeType = mimeType.split(';')[0].trim();
        }

        HttpRequest req = new HttpRequest();
        // diarize=true enables speaker detection, utterances=true groups speech by speaker turn
        req.setEndpoint('callout:Deepgram_API/v1/listen?model=nova-2&smart_format=true&punctuate=true&diarize=true&utterances=true&mip_opt_out=true');
        req.setMethod('POST');
        req.setHeader('Content-Type', mimeType);
        req.setBodyAsBlob(audioBlob);
        req.setTimeout(120000);

        System.debug('AudioNoteController: calling Deepgram — ' + req.getEndpoint());
        HttpResponse res = new Http().send(req);

        System.debug('AudioNoteController: Deepgram HTTP ' + res.getStatusCode());
        System.debug('AudioNoteController: Deepgram body = ' + res.getBody());

        if (res.getStatusCode() != 200) {
            throw new AuraHandledException(
                'Deepgram error (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        return parseDeepgramResponseWithSpeakers(res.getBody());
    }

    // ─── Parse Deepgram JSON with Speaker Diarization ────────────────────────
    //
    // Deepgram utterances response shape:
    // {
    //   "utterances": [
    //     { "speaker": 0, "transcript": "Good morning missus Roy." },
    //     { "speaker": 1, "transcript": "Oh good morning missus Gupta." },
    //     ...
    //   ]
    // }
    //
    // Output format:
    //   Speaker 1: Good morning missus Roy.
    //   Speaker 2: Oh good morning missus Gupta.
    // ─────────────────────────────────────────────────────────────────────────

    private static String parseDeepgramResponseWithSpeakers(String responseBody) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);

            // ── Try utterances first (best for diarized speaker-turn output) ──
            List<Object> utterances = (List<Object>) root.get('utterances');

            if (utterances != null && !utterances.isEmpty()) {
                List<String> lines = new List<String>();
                for (Object u : utterances) {
                    Map<String, Object> utterance = (Map<String, Object>) u;
                    Integer speakerNum  = Integer.valueOf(String.valueOf(utterance.get('speaker')));
                    String  speakerText = (String) utterance.get('transcript');

                    if (String.isNotBlank(speakerText)) {
                        // Speaker index from Deepgram is 0-based; display as 1-based
                        lines.add('Speaker ' + (speakerNum + 1) + ': ' + speakerText.trim());
                    }
                }

                if (!lines.isEmpty()) {
                    return String.join(lines, '\n');
                }
            }

            // ── Fallback: use word-level speaker tags from channels ───────────
            Map<String, Object> results  = (Map<String, Object>) root.get('results');
            if (results == null) {
                throw new AuraHandledException('Deepgram returned no results. Response: ' + responseBody);
            }

            List<Object> channels = (List<Object>) results.get('channels');
            if (channels == null || channels.isEmpty()) {
                throw new AuraHandledException('No audio channels found in Deepgram response.');
            }

            List<Object> alternatives = (List<Object>) ((Map<String, Object>) channels[0]).get('alternatives');
            if (alternatives == null || alternatives.isEmpty()) {
                throw new AuraHandledException('No transcription alternatives in Deepgram response.');
            }

            Map<String, Object> bestAlt = (Map<String, Object>) alternatives[0];

            // Try word-level diarization
            List<Object> words = (List<Object>) bestAlt.get('words');
            if (words != null && !words.isEmpty()) {
                return buildTranscriptFromWords(words);
            }

            // Last resort: plain transcript
            String transcript = (String) bestAlt.get('transcript');
            if (String.isBlank(transcript)) {
                throw new AuraHandledException('Deepgram returned an empty transcript. Please speak clearly and try again.');
            }
            return transcript;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to parse Deepgram response: ' + e.getMessage());
        }
    }

    /**
     * Builds a speaker-labelled transcript from Deepgram word-level diarization.
     * Groups consecutive words from the same speaker into a single line.
     */
    private static String buildTranscriptFromWords(List<Object> words) {
        List<String> lines          = new List<String>();
        Integer      currentSpeaker = -1;
        List<String> currentWords   = new List<String>();

        for (Object w : words) {
            Map<String, Object> word      = (Map<String, Object>) w;
            Object              spkObj    = word.get('speaker');
            Integer             speaker   = spkObj != null ? Integer.valueOf(String.valueOf(spkObj)) : 0;
            String              wordText  = (String) word.get('punctuated_word');
            if (String.isBlank(wordText)) {
                wordText = (String) word.get('word');
            }

            if (speaker != currentSpeaker) {
                // Flush previous speaker's words
                if (!currentWords.isEmpty()) {
                    lines.add('Speaker ' + (currentSpeaker + 1) + ': ' + String.join(currentWords, ' '));
                    currentWords = new List<String>();
                }
                currentSpeaker = speaker;
            }

            if (String.isNotBlank(wordText)) {
                currentWords.add(wordText);
            }
        }

        // Flush last speaker
        if (!currentWords.isEmpty()) {
            lines.add('Speaker ' + (currentSpeaker + 1) + ': ' + String.join(currentWords, ' '));
        }

        return lines.isEmpty() ? '' : String.join(lines, '\n');
    }

    // ─── Utilities ────────────────────────────────────────────────────────────

    private static String getExtension(String mimeType) {
        if (String.isBlank(mimeType)) return 'webm';
        if (mimeType.contains('mp4'))  return 'mp4';
        if (mimeType.contains('ogg'))  return 'ogg';
        if (mimeType.contains('wav'))  return 'wav';
        return 'webm';
    }
}
