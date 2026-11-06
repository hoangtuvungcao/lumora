#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include <string.h>

// Lumora runs once per data folder: a second launch (e.g. a clicked
// lumora:// link, lumora.desktop has `Exec=lumora %u`) registers with the same
// D-Bus application id, finds the running instance, hands it the link through
// the "open-link" action and exits. The running instance brings its window to
// the front and forwards the link to Dart over the "lumora/links" channel
// (lib/platform/desktop_links.dart).

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;          // the main window, once created (owned by GTK)
  FlMethodChannel* links;     // "lumora/links"
  gboolean links_ready;       // Dart listens on the channel
  GPtrArray* queued_links;    // links that arrived before Dart listened
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static const char kLinkScheme[] = "lumora://";
static const guint kMaxQueuedLinks = 8;
static const gsize kMaxLinkLength = 4096;

// The first lumora:// argument (scheme normalised to lower case), or nullptr.
static gchar* find_link(char** args) {
  const gsize n = strlen(kLinkScheme);
  for (char** a = args; a != nullptr && *a != nullptr; a++) {
    const gsize len = strlen(*a);
    if (len > n && len <= kMaxLinkLength && g_ascii_strncasecmp(*a, kLinkScheme, n) == 0) {
      return g_strconcat(kLinkScheme, *a + n, nullptr);
    }
  }
  return nullptr;
}

static void deliver_link(MyApplication* self, const gchar* link) {
  if (self->links != nullptr && self->links_ready) {
    g_autoptr(FlValue) arg = fl_value_new_string(link);
    fl_method_channel_invoke_method(self->links, "open", arg, nullptr, nullptr, nullptr);
  } else if (self->queued_links->len < kMaxQueuedLinks) {
    g_ptr_array_add(self->queued_links, g_strdup(link));
  }
}

// "open-link" action: activated in this (running) instance by a later launch.
static void open_link_cb(GSimpleAction* action, GVariant* parameter, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window != nullptr) gtk_window_present(self->window);
  const gchar* raw = g_variant_get_string(parameter, nullptr);
  char* args[] = {const_cast<char*>(raw), nullptr};
  g_autofree gchar* link = find_link(args);
  if (link != nullptr) deliver_link(self, link);
}

// "lumora/links" channel: Dart says "ready" and gets the links that came before.
static void links_method_cb(FlMethodChannel* channel, FlMethodCall* method_call, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (strcmp(fl_method_call_get_name(method_call), "ready") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  g_autoptr(FlValue) list = fl_value_new_list();
  for (guint i = 0; i < self->queued_links->len; i++) {
    fl_value_append_take(list, fl_value_new_string(static_cast<const gchar*>(g_ptr_array_index(self->queued_links, i))));
  }
  g_ptr_array_set_size(self->queued_links, 0);
  self->links_ready = TRUE;
  fl_method_call_respond_success(method_call, list, nullptr);
}

// Application id: one instance per data folder (LUMORA_DATA_DIR lets tests and
// power users run several profiles side by side).
static gchar* application_id() {
  const gchar* dir = g_getenv("LUMORA_DATA_DIR");
  if (dir == nullptr || *dir == '\0') return g_strdup(APPLICATION_ID);
  g_autofree gchar* hash = g_compute_checksum_for_string(G_CHECKSUM_SHA256, dir, -1);
  hash[16] = '\0';
  return g_strdup_printf("%s.d%s", APPLICATION_ID, hash);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {  // launched again: show the window we have
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window), reinterpret_cast<gpointer*>(&self->window));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Lumora");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Lumora");
  }

  gtk_window_set_default_size(window, 1280, 800);
  GdkGeometry geometry;
  geometry.min_width = 900;
  geometry.min_height = 600;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  // Window/taskbar icon from the bundled asset.
  {
    g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
    if (exe != nullptr) {
      g_autofree gchar* dir = g_path_get_dirname(exe);
      g_autofree gchar* icon = g_build_filename(dir, "data", "flutter_assets", "assets",
                                                "icons", "lumora-256.png", nullptr);
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->links);
  self->links = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                      "lumora/links", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->links, links_method_cb, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  if (g_application_get_is_remote(application)) {
    // Lumora already runs with this data folder: hand it our link (or just
    // bring it to the front) and quit. g_application_run flushes the bus.
    g_autofree gchar* link = find_link(self->dart_entrypoint_arguments);
    if (link != nullptr && g_action_group_has_action(G_ACTION_GROUP(application), "open-link")) {
      g_action_group_activate_action(G_ACTION_GROUP(application), "open-link", g_variant_new_string(link));
    } else {
      g_application_activate(application);
    }
    *exit_status = 0;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  if (self->window != nullptr) {
    g_object_remove_weak_pointer(G_OBJECT(self->window), reinterpret_cast<gpointer*>(&self->window));
    self->window = nullptr;
  }
  g_clear_object(&self->links);
  g_clear_pointer(&self->queued_links, g_ptr_array_unref);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->queued_links = g_ptr_array_new_with_free_func(g_free);
  // Added before registration so a later launch sees it on the bus.
  g_autoptr(GSimpleAction) open_link = g_simple_action_new("open-link", G_VARIANT_TYPE_STRING);
  g_signal_connect(open_link, "activate", G_CALLBACK(open_link_cb), self);
  g_action_map_add_action(G_ACTION_MAP(self), G_ACTION(open_link));
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  g_autofree gchar* id = application_id();
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", id, "flags",
                                     static_cast<GApplicationFlags>(0), nullptr));
}
