# What's new in 4.1.2

- Fixed: a KDE app watching its settings, such as EasyEffects, could freeze
  and use more and more memory after a theme change. Omarchroma no longer
  sends the signal that caused it; KDE apps take new colors on restart.
