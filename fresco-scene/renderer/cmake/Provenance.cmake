set_property(TARGET fresco-scene-helper-main PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing)
set_property(TARGET fresco-scene-protocol PROPERTY
    FRESCO_SCENE_PROVENANCE contract-document-only)
set_property(TARGET fresco-scene-session PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing)
set_property(TARGET fresco-scene-scheduler PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing)
set_property(TARGET fresco-scene-change-index PROPERTY
    FRESCO_SCENE_PROVENANCE original-stage3-mechanism)
set_property(TARGET fresco-scene-draw-contract PROPERTY
    FRESCO_SCENE_PROVENANCE structural-placeholder)
set_property(TARGET fresco-scene-evidence PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing)
set_property(TARGET fresco-scene-audio PROPERTY
    FRESCO_SCENE_PROVENANCE derived-or-unclear-gpl-side)
set_property(TARGET fresco-scene-media PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing-gpl-side)
set_property(TARGET fresco-scene-particle-compatibility PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing-gpl-side)
set_property(TARGET fresco-scene-sound-semantic PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing-gpl-side)

foreach(target IN ITEMS
    fresco-scene-system-script
    fresco-scene-system-audio
    fresco-scene-system-media
    fresco-scene-system-particles
    fresco-scene-system-puppet
    fresco-scene-system-text-effects
    fresco-scene-system-effects
    fresco-scene-systems
    fresco-scene-we-runtime
    fresco-scene-legacy-gl)
    set_property(TARGET ${target} PROPERTY
        FRESCO_SCENE_PROVENANCE derived-or-unclear-gpl-side)
endforeach()

set_property(TARGET fresco-scene-we-import PROPERTY
    FRESCO_SCENE_PROVENANCE pinned-upstream-gpl)
set_property(TARGET fresco-scene-we-generated PROPERTY
    FRESCO_SCENE_PROVENANCE generated-from-pinned-upstream-gpl)
set_property(TARGET ${fresco_scene_surface_target} PROPERTY
    FRESCO_SCENE_PROVENANCE original-existing-gpl-side)
set_property(TARGET fresco-scene-renderer-core PROPERTY
    FRESCO_SCENE_PROVENANCE compatibility-aggregate-gpl-side)

# These targets group object owners without forwarding their object files.
# renderer-core expands each object target exactly once until the existing
# cross-module symbol cycles can be removed.
set_property(TARGET fresco-scene-systems PROPERTY
    FRESCO_SCENE_TARGET_ROLE non-owning-object-group)
set_property(TARGET fresco-scene-we-runtime PROPERTY
    FRESCO_SCENE_TARGET_ROLE non-owning-object-group)
