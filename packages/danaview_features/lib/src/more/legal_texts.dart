// EXTENDED: S2-W (slice S2 share of INT-106: the Files & Media Home text, shown only in builds with
// DANAVIEW_FILES_HOME, BUILD_PLAN v1.2 §1A)
// EXTENDED: S3-W (slice S3 share of INT-106: documents, Open with Danaview and the iOS Share
// Extension, in the same builds; ARCH v1.2 §5.2, §5.6, §9.3)
// EXTENDED: S4-W (slice S4 share of INT-106: the PDF tools and saved signatures, in the same builds;
// HOM plan §8.5, ARCH v1.2 §5.2, §9.1)

/// The Privacy Policy and Terms of Use as structured data, rendered by the legal screen.
///
/// Edited in order UX-42 (v1.1) → ST-05 (speed-test providers, V2-406) → S2-W (Files & Media Home)
/// → S3-W (documents, share-in) → S4-W (PDF tools, saved signatures) → AIS-36 → INT-106 (ARCH §9.5).
library;

import '../flags.dart';

/// Where the app shows the third-party licences (the Auto captions terms point here, ARCH §20.3).
const String openSourceLicencesLocation = 'Settings › About › Open-source licences';

const String danaviewCopyright = 'Copyright © 2026 vecvel. All rights reserved.';

/// Bumped to the release date of the version that ships the video editor (INT-05).
const String legalEffectiveDate = '11 October 2026';

/// A paragraph, or a bulleted list when [bullets] is set.
class LegalBlock {
  const LegalBlock.paragraph(String this.text) : bullets = null;

  const LegalBlock.bullets(List<LegalBullet> this.bullets) : text = null;

  final String? text;
  final List<LegalBullet>? bullets;
}

/// One list item; [lead] is set in bold before the text.
class LegalBullet {
  const LegalBullet(this.text, {this.lead});

  final String text;
  final String? lead;
}

class LegalSection {
  const LegalSection(this.heading, this.blocks);

  final String heading;
  final List<LegalBlock> blocks;
}

class LegalDocumentText {
  const LegalDocumentText({
    required this.title,
    required this.summary,
    required this.sections,
    required this.contactPrompt,
  });

  final String title;

  /// The short version, shown first.
  final String summary;
  final List<LegalSection> sections;

  /// Lead-in for the contact line, shown only when a support email is set.
  final String contactPrompt;
}

// ---- Files & Media Home (S2-W; ARCH v1.2 §5.2–§5.4, §9.4, §9.5) ----
//
// The bullets below join the policy and the terms only in builds with DANAVIEW_FILES_HOME (the S2
// release candidate and later), so a build without the Home never describes it. INT-106 folds them
// into the final 1.2.0 text.

/// What the Files & Media Home stores ("What Danaview stores on your device").
const List<LegalBullet> filesHomeStoredBullets = [
  LegalBullet(
    lead: 'Danaview folders',
    'Photos, videos, documents and other files you import into Danaview folders, from your photo library, '
    'your files or other apps. Every import is a copy: the original is never changed, moved or deleted. '
    "Danaview folders live in Danaview's own storage on this device and are not shown in other apps.",
  ),
  LegalBullet(
    lead: 'Library database',
    'A small database on your device that lists your Danaview folders and files: names, sizes, dates, '
    'favourites, the last 50 files you opened, how you sort each folder, and photo details read from the '
    'files themselves, such as the date taken, camera and size in pixels.',
  ),
  LegalBullet(
    lead: 'Recently deleted',
    'Files and folders you delete from Danaview folders are kept in Recently deleted for 30 days so you can '
    'restore them, and are then removed for good. Until then they still use storage on your device.',
  ),
  LegalBullet(
    lead: 'Thumbnails',
    'Small previews of your photos, videos and files, kept in the app\'s cache so the Home scrolls smoothly. '
    'They are not included in backups and are made again when needed.',
  ),
];

/// What backups include (its own paragraph after the stored-data list).
const String filesHomeBackupText =
    'Backups: on iPhone, iPad and Mac, Danaview folders, Recently deleted and the library database are '
    'included in your device and iCloud backups; an import that has not finished yet is not. On Android they '
    "are not in Google's cloud backup, which holds at most 25 MB per app (a larger app would lose its whole "
    'cloud backup, your player data included); they move to a new phone with a direct phone-to-phone '
    'transfer, or you can save them out first. '
    "On computers they are kept in the app's data folder and are part of any backup you make of it.";

/// Photo library access and getting files out ("Files and permissions").
const List<LegalBullet> filesHomePermissionBullets = [
  LegalBullet(
    lead: 'Photo library on the Home',
    'Only if you choose "Show my photo library" in the Photos tab, Danaview asks to see your photo library '
    'and shows its photos there. On iPhone and iPad you can allow only selected photos, and on Android 14 '
    'and later only selected photos and videos. Danaview only reads your photo library; it never changes or '
    'deletes anything in it. Importing with the photo picker needs no access: Danaview receives only the '
    'items you pick.',
  ),
  LegalBullet(
    lead: 'Pictures folders on computers',
    'On Mac, Windows and Linux, the Photos tab can also list the pictures in your Pictures folder and on '
    'connected drives once you choose to show them. Danaview only reads these files.',
  ),
  LegalBullet(
    lead: 'Saving and sharing files',
    'Save to Files, Save to Downloads, Save to Photos, Share and Open in another app always hand over a copy; '
    'a copy made for sharing is temporary and removed afterwards, and saving to your photo library adds the '
    'copy without reading the rest of the library.',
  ),
];

/// The Files & Media Home choices ("Your choices").
const List<LegalBullet> filesHomeChoiceBullets = [
  LegalBullet(
    'Restore files or remove them for good in Home › Folders › Recently deleted (Empty now), and see how much '
    'space Danaview folders and Recently deleted use in Settings › Library storage.',
  ),
  LegalBullet('Clear the list of files you opened recently with Clear under Recents on Home.'),
  LegalBullet("Allow or remove Danaview's access to your photo library at any time in your device's settings."),
  LegalBullet(
    'Danaview folders are stored inside the app: uninstalling Danaview, or on Android clearing its storage, '
    'deletes them and everything in them. Save the files you want to keep somewhere else first.',
  ),
];

/// The Terms of Use section of the Files & Media Home.
const LegalSection filesHomeTermsSection = LegalSection('Danaview folders', [
  LegalBlock.paragraph(
    "Files you import are copies kept in Danaview's own storage on your device. Removing a file from "
    'Recently deleted, with Empty now or after 30 days, is permanent, and uninstalling the app removes '
    'Danaview folders and everything in them. Keep your own backups of files you care about.',
  ),
]);

// ---- Documents and share-in (S3-W; ARCH v1.2 §3, §5.2, §5.6, §9.3) ----
//
// Same builds as the Files & Media Home text above (DANAVIEW_FILES_HOME). INT-106 folds them into
// the final 1.2.0 text.

/// Files other apps hand to Danaview ("What Danaview stores on your device").
const List<LegalBullet> documentsStoredBullets = [
  LegalBullet(
    lead: 'Files shared with Danaview',
    'When you open a photo or document with Danaview, or share photos, videos or documents to Danaview from '
    'another app, Danaview saves a copy in your Danaview folders (in Imported, or in the folder you pick when '
    'sharing). The original in the other app is never changed.',
  ),
  LegalBullet(
    lead: 'Share extension (iPhone and iPad)',
    'When you share to Danaview, its share extension first puts the copy in a storage area on your device that '
    'only Danaview and its extension can use. Danaview moves it into your Danaview folders the next time it '
    'opens and then removes it from that area; a share that was interrupted is removed after 24 hours. So the '
    'extension can list your folders, Danaview also keeps the names of your Danaview folders there (no file '
    'names). This area is not included in backups.',
  ),
];

/// Viewing documents ("Files and permissions").
const List<LegalBullet> documentsPermissionBullets = [
  LegalBullet(
    lead: 'Documents',
    "PDFs, Office files, text and other documents open on your device: PDFs in Danaview's PDF viewer, text "
    'and spreadsheets in its own viewers, and on iPhone, iPad and Mac other files in the system preview as '
    "read-only previews. Viewing never changes the file. A file Danaview can't show goes to another app only "
    'when you choose Open in another app.',
  ),
  LegalBullet(
    lead: 'Documents in your folders',
    'The Documents tab also lists the documents in the folders you added to your library. Danaview only reads '
    'their names, sizes and dates to list them, and opens one only when you do; it never renames, moves or '
    'deletes them.',
  ),
  LegalBullet(
    lead: 'Opening files with Danaview',
    'Photos and documents another app opens with Danaview are copied into Imported and shown. Videos, streams '
    'and links opened with Danaview play as before.',
  ),
];

/// The Terms of Use section on documents.
const LegalSection documentsTermsSection = LegalSection('Documents', [
  LegalBlock.paragraph(
    'Danaview shows documents for reading only, and viewing never changes them. A document can look different '
    'from the app that made it; to edit one, use Open in another app.',
  ),
]);

// ---- PDF tools and saved signatures (S4-W; HOM plan §8.5, ARCH v1.2 §5.2, §9.1) ----
//
// Same builds as the blocks above (DANAVIEW_FILES_HOME). The tools run where the platform's PDF
// engine offers them (iPhone, iPad, Mac, Android); the text names no platform so it stays true as
// the Android annotate and sign tools arrive. INT-106 folds them into the final 1.2.0 text.

/// Saved signatures ("What Danaview stores on your device").
const List<LegalBullet> pdfToolsStoredBullets = [
  LegalBullet(
    lead: 'Saved signatures',
    'If you save a signature to sign PDFs (drawn, typed or made from a photo), Danaview keeps it as a picture '
    "only on this device, in the app's private storage. Saved signatures are not in your Danaview folders, are "
    'not shown in other apps, and are not included in backups or moved to a new device. You can keep up to '
    '10; delete one while signing, or all of them in Settings › Privacy. A photo you pick for a signature is '
    'used only to make that picture and is then deleted.',
  ),
];

/// The PDF tools ("Files and permissions").
const List<LegalBullet> pdfToolsPermissionBullets = [
  LegalBullet(
    lead: 'PDF tools',
    'Organise pages, Merge, Annotate, Sign and Compress run entirely on your device; nothing is uploaded. '
    'Each saves its result as a new file next to the original, or in Imported for a file from another app or '
    'folder, and the original is never changed. Only if you choose Replace for a PDF in your Danaview folders '
    'is that file overwritten by the new version. Signing places a picture of your signature on the page; it '
    'is not a certificate-based digital signature. Importing a signature from a photo uses the system photo '
    'picker (the file picker on Mac), so Danaview receives only the photo you pick.',
  ),
];

/// The saved-signature choice ("Your choices").
const List<LegalBullet> pdfToolsChoiceBullets = [
  LegalBullet('Delete saved signatures one by one while signing, or all at once in Settings › Privacy.'),
];

/// The Terms of Use section on the PDF tools.
const LegalSection pdfToolsTermsSection = LegalSection('PDF tools and signatures', [
  LegalBlock.paragraph(
    'The PDF tools save new files and leave the original as it was, unless you choose Replace for a file in '
    'your Danaview folders. A signature you place with Danaview is a picture of your signature, not a '
    'certificate-based digital signature, and Danaview does not verify who signed. Sign only documents you '
    'are entitled to sign, and check the result before you share it.',
  ),
]);

const LegalDocumentText privacyPolicyText = LegalDocumentText(
  title: 'Privacy Policy',
  summary: 'Danaview keeps everything on your device. There are no accounts, no analytics, no ads and no '
      'tracking, and nothing you watch, edit or type is sent to us. The only extra download is the optional '
      'speech model for Auto captions, and only after you agree.',
  contactPrompt: 'Questions about this policy?',
  sections: [
    LegalSection('Who we are', [
      LegalBlock.paragraph(
        'Danaview ("the app") is made by vecvel. This policy explains what the app stores, '
        'where it stores it, and when it connects to the internet.',
      ),
    ]),
    LegalSection('What Danaview stores on your device', [
      LegalBlock.paragraph('To work the way you expect, Danaview saves a few things in its own storage on your device:'),
      LegalBlock.bullets([
        LegalBullet('Watch history and resume points, so you can continue where you left off.'),
        LegalBullet(
          'Playlists and the library folders you add. Folders are saved as references to where they are; your '
          'files are never copied, moved or changed.',
        ),
        LegalBullet(
          'Per-video settings, such as subtitle and audio delay and picture adjustments, and app preferences '
          'like volume, playback speed and double-tap seek.',
        ),
        LegalBullet(
          'Your profile, if you choose to fill it in: name, email address, phone number and date of birth. '
          'Every field is optional.',
        ),
        LegalBullet(
          'On iPhone, iPad and Android, video editing projects: your edits and the files the editor makes for '
          'them, such as voice recordings, freeze frames, reversed clips, optimized copies for smoother editing, '
          'thumbnails and audio waveforms. Projects refer to your original videos, photos and music where they '
          'are. Editing never changes, moves, renames or deletes your originals. On Android, video editing '
          'projects are not included in device backups.',
        ),
        LegalBullet(
          'On iPhone, iPad and Android, videos and photos you add to a project from your photo library, and files '
          "you drop into the editor, are copied into Danaview's own storage so the project keeps working. Deleting a "
          'project removes copies no other project uses.',
        ),
        LegalBullet(
          'On iPhone, iPad and Android, if you use Auto captions: the speech model you downloaded, and the text '
          'transcribed from your videos so captions can be adjusted later without transcribing again. They are '
          'never uploaded.',
        ),
        if (FeatureFlags.filesHome) ...filesHomeStoredBullets,
        if (FeatureFlags.filesHome) ...documentsStoredBullets,
        if (FeatureFlags.filesHome) ...pdfToolsStoredBullets,
      ]),
      if (FeatureFlags.filesHome) LegalBlock.paragraph(filesHomeBackupText),
      LegalBlock.paragraph(
        'This information stays on your device. It is not uploaded, synced or shared, and we cannot see it.',
      ),
    ]),
    LegalSection("What Danaview doesn't do", [
      LegalBlock.bullets([
        LegalBullet('No accounts or sign-in.'),
        LegalBullet('No analytics, telemetry or crash reporting.'),
        LegalBullet('No advertising and no advertising identifiers.'),
        LegalBullet(
          'No tracking across apps or websites, and no selling or sharing of personal data. The one exception '
          'is a speed test you agree to run on the open measurement network, described below.',
        ),
      ]),
    ]),
    LegalSection('When Danaview uses the internet', [
      LegalBlock.paragraph('Danaview connects to the internet only when you ask it to:'),
      LegalBlock.bullets([
        LegalBullet(
          lead: 'Videos and streams',
          'When you open a link, Danaview fetches the video directly from that address. Like any website, the '
          'server that hosts it sees the usual details of the connection, such as your IP address, and handles '
          'them under its own policies.',
        ),
        LegalBullet(
          lead: 'Speed test',
          "By default, the test exchanges test data directly with Cloudflare's public speed test servers "
          '(speed.cloudflare.com) to measure latency, download and upload speed. It sends no personal data, '
          'profile details or viewing history. Cloudflare sees the usual details of the connection, such as '
          'your IP address, and handles them under its own policies.',
        ),
        LegalBullet(
          lead: 'Speed test on the open measurement network',
          'Only if the usual test servers are busy or unreachable, and only if you agree when asked, the test '
          'runs on Measurement Lab (M-Lab), an open network that measures internet performance for research. '
          'Danaview asks locate.measurementlab.net for a nearby test server and then exchanges test data with '
          'that server (an address on measurement-lab.org). It sends no personal data, profile details or '
          'viewing history. M-Lab publishes the results of every test publicly, including your IP address. '
          'Your answer is remembered, and you can change it at any time in Settings › Privacy. If you say no, '
          'the test never uses M-Lab.',
        ),
        LegalBullet(
          lead: 'Stream check',
          'Contacts the address you enter, plus any address it redirects to and, for a playlist, its first '
          'quality level, to see whether the link responds and what it serves. Only a small part of a file '
          'is downloaded.',
        ),
        LegalBullet(
          lead: 'Speech model for Auto captions',
          'On iPhone, iPad and Android, only if you choose to create captions automatically, and only after you '
          'agree, Danaview downloads a speech recognition model (about 31 to 181 MB, depending on the quality you '
          'pick) from Hugging Face (huggingface.co), which delivers it through its download network on hf.co. '
          'The request contains only the model\'s file name. No video, audio, captions or personal data are '
          'sent. Hugging Face sees the usual details of the connection, such as your IP address, and handles them '
          'under its own policies. After the download, captions are created entirely on your device, even when '
          'you are offline.',
        ),
      ]),
      LegalBlock.paragraph(
        'Files on your device that you play, edit, inspect, export or browse are processed on your device and '
        'are never uploaded.',
      ),
    ]),
    LegalSection('Files and permissions', [
      LegalBlock.paragraph(
        'Danaview reads only the files and folders you choose to open, add to your library or add to a project, and '
        "on phones and tablets the videos you place in its own folder. It doesn't scan the rest of your storage, "
        'and it never changes, moves or deletes your videos, photos or music.',
      ),
      LegalBlock.bullets([
        LegalBullet(
          lead: 'Photo library',
          'On iPhone, iPad and Android, when you add photos or videos to a project, Danaview receives only the items you pick. When you save an '
          "export to Photos or your gallery, Danaview adds that video and doesn't read the rest of your library.",
        ),
        LegalBullet(
          lead: 'Microphone',
          'On iPhone, iPad and Android, used only while you record a voiceover in the editor. Recordings stay in that project on your device.',
        ),
        LegalBullet(
          lead: 'Notifications (Android)',
          'Used only to show export and caption progress while Danaview is in the background, if you allow it.',
        ),
        if (FeatureFlags.filesHome) ...filesHomePermissionBullets,
        if (FeatureFlags.filesHome) ...documentsPermissionBullets,
        if (FeatureFlags.filesHome) ...pdfToolsPermissionBullets,
      ]),
    ]),
    LegalSection('Your choices', [
      LegalBlock.bullets([
        LegalBullet('Edit or clear your profile at any time in Settings › Profile.'),
        LegalBullet('Allow or stop speed tests on the open measurement network at any time in Settings › Privacy.'),
        LegalBullet(
          'Clear your watch history and resume points from Continue watching on Home, or manage saved data in '
          'Settings › Storage & history.',
        ),
        LegalBullet(
          "On iPhone, iPad and Android, delete video editing projects in the editor's Projects screen. This "
          'removes the project and the files made for it, never your originals.',
        ),
        LegalBullet(
          'On iPhone, iPad and Android, delete the Auto captions speech model, and clear editor thumbnails, waveforms and optimized copies, in '
          'Settings › Storage & history or Settings › Video editor.',
        ),
        LegalBullet(
          'On phones and tablets, uninstalling Danaview removes everything it stored, and on Android so does '
          'clearing its storage in system settings.',
        ),
        LegalBullet(
          'On computers, uninstalling may leave its saved settings behind. Clear your profile in Settings › '
          'Profile and your history in Settings › Storage & history first.',
        ),
        if (FeatureFlags.filesHome) ...filesHomeChoiceBullets,
        if (FeatureFlags.filesHome) ...pdfToolsChoiceBullets,
      ]),
    ]),
    LegalSection("Children's privacy", [
      LegalBlock.paragraph(
        "Danaview doesn't collect personal information from anyone, including children. Anything entered in the "
        'app stays on the device it was entered on.',
      ),
    ]),
    LegalSection('Changes to this policy', [
      LegalBlock.paragraph(
        'If this policy changes, the updated version will appear in the app with a new effective date.',
      ),
    ]),
  ],
);

const LegalDocumentText termsOfUseText = LegalDocumentText(
  title: 'Terms of Use',
  summary: 'Danaview is provided as is, for personal and evaluation use. You are responsible for what you open '
      'and play with it.',
  contactPrompt: 'Questions about these terms?',
  sections: [
    LegalSection('Agreement', [
      LegalBlock.paragraph(
        'These terms apply to your use of Danaview ("the app"), made by vecvel. By installing or '
        "using the app you agree to them. If you don't agree, please don't use the app.",
      ),
    ]),
    LegalSection('License', [
      LegalBlock.paragraph(
        'Danaview is proprietary software. $danaviewCopyright You may view and test the app for personal and '
        'evaluation purposes only. You may not:',
      ),
      LegalBlock.bullets([
        LegalBullet(
          'Copy, modify, adapt, translate, distribute, sell, lease or sublicense the app or any part of it without '
          'prior written consent from vecvel.',
        ),
        LegalBullet('Reverse engineer, decompile or disassemble the app, except where applicable law allows it.'),
        LegalBullet('Remove, alter or obscure any proprietary notices, labels or marks.'),
      ]),
    ]),
    LegalSection('Your content', [
      LegalBlock.paragraph(
        'Danaview plays and edits the files and streams you choose. You are responsible for the content you open, '
        'edit and publish with it, and for having the rights to the footage, music, images and fonts you use. '
        "vecvel doesn't provide, host or endorse any content you play or create.",
      ),
      LegalBlock.paragraph(
        "Don't use Danaview to break the law, to infringe anyone's rights, or to disrupt the services you stream "
        'from or test against.',
      ),
    ]),
    LegalSection('Editing and exports', [
      LegalBlock.paragraph(
        'On iPhone, iPad and Android, the video editor never changes your original files; exports are new files. '
        'Keep your own backups of projects and exports you care about. Export presets named after YouTube, '
        'Instagram or TikTok are conveniences and are not made or endorsed by those services.',
      ),
    ]),
    if (FeatureFlags.filesHome) filesHomeTermsSection,
    if (FeatureFlags.filesHome) documentsTermsSection,
    if (FeatureFlags.filesHome) pdfToolsTermsSection,
    LegalSection('Auto captions', [
      LegalBlock.paragraph(
        'On iPhone, iPad and Android, automatically created captions may contain mistakes. Review them before you '
        'publish or share a video.',
      ),
      LegalBlock.paragraph(
        'Danaview uses open-source software and fonts and, on iPhone, iPad and Android, open-source speech '
        'recognition models for Auto captions, each under its own licence. You can read these licences in '
        '$openSourceLicencesLocation.',
      ),
    ]),
    LegalSection('Trademarks', [
      LegalBlock.paragraph(
        '"Danaview", "vecvel" and associated logos are trademarks of vecvel. YouTube, Instagram and TikTok are '
        'trademarks of their respective owners.',
      ),
    ]),
    LegalSection('No warranty', [
      LegalBlock.paragraph(
        'The app is provided "as is", without warranty of any kind, express or implied, including the warranties '
        'of merchantability, fitness for a particular purpose and non-infringement. Results from the built-in '
        'tools, such as speed test measurements and data usage estimates, export size estimates and '
        'automatically created captions, are approximate.',
      ),
    ]),
    LegalSection('Limitation of liability', [
      LegalBlock.paragraph(
        'To the fullest extent the law allows, vecvel and the authors of the app are not liable for any claim, '
        'damages or other liability, whether in contract, tort or otherwise, arising from, out of or in '
        "connection with the app or its use. Some places don't allow certain limitations, so parts of this "
        'section may not apply to you.',
      ),
    ]),
    LegalSection('Privacy', [
      LegalBlock.paragraph('How the app handles information is described in the Privacy Policy.'),
    ]),
    LegalSection('Changes to these terms', [
      LegalBlock.paragraph(
        'These terms may change from time to time. The current version and its effective date are always '
        'available in Settings › About. If you keep using the app after a change, you accept the updated terms.',
      ),
    ]),
  ],
);
