function toggleMobileMenu() {
  const nav = document.getElementById('main-nav');
  nav.classList.toggle('active');
}

// Close mobile menu when clicking outside
document.addEventListener('click', function(event) {
  const nav = document.getElementById('main-nav');
  const toggle = document.querySelector('.mobile-menu-toggle');
  
  if (nav && toggle && !nav.contains(event.target) && !toggle.contains(event.target)) {
    nav.classList.remove('active');
  }
});

// Close mobile menu when window is resized above mobile breakpoint
window.addEventListener('resize', function() {
  const nav = document.getElementById('main-nav');
  if (window.innerWidth > 700 && nav) {
    nav.classList.remove('active');
  }
});
