// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// The engine's FileProvider (authority `${applicationId}.danaview.editor.files`, paths in
// res/xml/danaview_editor_file_paths.xml; ARCH §14.3, §20.4). A subclass, so the manifest merge never
// clashes with another library that declares androidx.core.content.FileProvider itself. AND-12's
// FileHandoff builds URIs with `FileProvider.getUriForFile(context, ctx.fileProviderAuthority, file)`.

package com.vecvel.danaview.editor.engine.glue

import androidx.core.content.FileProvider

/** FileProvider of the editor engine (ARCH §20.4). */
class EditorFileProvider : FileProvider()
