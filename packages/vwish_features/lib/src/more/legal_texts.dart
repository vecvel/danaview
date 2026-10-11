/// The Privacy Policy and Terms of Use as structured data, rendered by the legal screen.
library;

const String vwishCopyright = 'Copyright © 2026 vecvel. All rights reserved.';

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

const LegalDocumentText privacyPolicyText = LegalDocumentText(
  title: 'Privacy Policy',
  summary: 'Vwish keeps everything on your device. There are no accounts, no analytics, no ads and no '
      'tracking, and nothing you watch, edit or type is sent to us. The only extra download is the optional '
      'speech model for Auto captions, and only after you agree.',
  contactPrompt: 'Questions about this policy?',
  sections: [
    LegalSection('Who we are', [
      LegalBlock.paragraph(
        'Vwish ("the app") is made by vecvel. This policy explains what the app stores, '
        'where it stores it, and when it connects to the internet.',
      ),
    ]),
    LegalSection('What Vwish stores on your device', [
      LegalBlock.paragraph('To work the way you expect, Vwish saves a few things in its own storage on your device:'),
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
          "you drop into the editor, are copied into Vwish's own storage so the project keeps working. Deleting a "
          'project removes copies no other project uses.',
        ),
        LegalBullet(
          'On iPhone, iPad and Android, if you use Auto captions: the speech model you downloaded, and the text '
          'transcribed from your videos so captions can be adjusted later without transcribing again. They are '
          'never uploaded.',
        ),
      ]),
      LegalBlock.paragraph(
        'This information stays on your device. It is not uploaded, synced or shared, and we cannot see it.',
      ),
    ]),
    LegalSection("What Vwish doesn't do", [
      LegalBlock.bullets([
        LegalBullet('No accounts or sign-in.'),
        LegalBullet('No analytics, telemetry or crash reporting.'),
        LegalBullet('No advertising and no advertising identifiers.'),
        LegalBullet('No tracking across apps or websites, and no selling or sharing of personal data.'),
      ]),
    ]),
    LegalSection('When Vwish uses the internet', [
      LegalBlock.paragraph('Vwish connects to the internet only when you ask it to:'),
      LegalBlock.bullets([
        LegalBullet(
          lead: 'Videos and streams',
          'When you open a link, Vwish fetches the video directly from that address. Like any website, the '
          'server that hosts it sees the usual details of the connection, such as your IP address, and handles '
          'them under its own policies.',
        ),
        LegalBullet(
          lead: 'Speed test',
          "The test exchanges test data directly with Cloudflare's public speed test servers "
          '(speed.cloudflare.com) to measure latency, download and upload speed. It sends no personal data, '
          'profile details or viewing history. Cloudflare sees the usual details of the connection, such as '
          'your IP address.',
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
          'agree, Vwish downloads a speech recognition model (about 31 to 181 MB, depending on the quality you '
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
        'Vwish reads only the files and folders you choose to open, add to your library or add to a project, and '
        "on phones and tablets the videos you place in its own folder. It doesn't scan the rest of your storage, "
        'and it never changes, moves or deletes your videos, photos or music.',
      ),
      LegalBlock.bullets([
        LegalBullet(
          lead: 'Photo library',
          'On iPhone, iPad and Android, when you add photos or videos to a project, Vwish receives only the items you pick. When you save an '
          "export to Photos or your gallery, Vwish adds that video and doesn't read the rest of your library.",
        ),
        LegalBullet(
          lead: 'Microphone',
          'On iPhone, iPad and Android, used only while you record a voiceover in the editor. Recordings stay in that project on your device.',
        ),
        LegalBullet(
          lead: 'Notifications (Android)',
          'Used only to show export and caption progress while Vwish is in the background, if you allow it.',
        ),
      ]),
    ]),
    LegalSection('Your choices', [
      LegalBlock.bullets([
        LegalBullet('Edit or clear your profile at any time in Settings › Profile.'),
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
          'On phones and tablets, uninstalling Vwish removes everything it stored, and on Android so does '
          'clearing its storage in system settings.',
        ),
        LegalBullet(
          'On computers, uninstalling may leave its saved settings behind. Clear your profile in Settings › '
          'Profile and your history in Settings › Storage & history first.',
        ),
      ]),
    ]),
    LegalSection("Children's privacy", [
      LegalBlock.paragraph(
        "Vwish doesn't collect personal information from anyone, including children. Anything entered in the "
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
  summary: 'Vwish is provided as is, for personal and evaluation use. You are responsible for what you open '
      'and play with it.',
  contactPrompt: 'Questions about these terms?',
  sections: [
    LegalSection('Agreement', [
      LegalBlock.paragraph(
        'These terms apply to your use of Vwish ("the app"), made by vecvel. By installing or '
        "using the app you agree to them. If you don't agree, please don't use the app.",
      ),
    ]),
    LegalSection('License', [
      LegalBlock.paragraph(
        'Vwish is proprietary software. $vwishCopyright You may view and test the app for personal and '
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
        'Vwish plays and edits the files and streams you choose. You are responsible for the content you open, '
        'edit and publish with it, and for having the rights to the footage, music, images and fonts you use. '
        "vecvel doesn't provide, host or endorse any content you play or create.",
      ),
      LegalBlock.paragraph(
        "Don't use Vwish to break the law, to infringe anyone's rights, or to disrupt the services you stream "
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
    LegalSection('Auto captions', [
      LegalBlock.paragraph(
        'On iPhone, iPad and Android, automatically created captions may contain mistakes. Review them before you '
        'publish or share a video.',
      ),
    ]),
    LegalSection('Trademarks', [
      LegalBlock.paragraph(
        '"Vwish", "vecvel" and associated logos are trademarks of vecvel. YouTube, Instagram and TikTok are '
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
