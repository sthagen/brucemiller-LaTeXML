# /=====================================================================\ #
# |  LaTeXML::Core::Stomach                                                   | #
# | Analog of TeX's Stomach: digests tokens, stores state               | #
# |=====================================================================| #
# | Part of LaTeXML:                                                    | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Bruce Miller <bruce.miller@nist.gov>                        #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #

package LaTeXML::Core::Stomach;
use strict;
use warnings;
use LaTeXML::Global;
use LaTeXML::Common::Object;
use LaTeXML::Common::Error;
use LaTeXML::Core::Token;
use LaTeXML::Core::Tokens;
use LaTeXML::Core::Gullet;
use LaTeXML::Core::Box;
use LaTeXML::Core::Comment;
use LaTeXML::Core::List;
use LaTeXML::Core::Mouth;
use LaTeXML::Common::Font;
# Silly place to import these....?
use LaTeXML::Common::Color;
use LaTeXML::Core::Definition;
use Scalar::Util qw(blessed);
use base         qw(LaTeXML::Common::Object);

DebuggableFeature('modes');

#**********************************************************************
sub new {
  my ($class, %options) = @_;
  return bless { gullet => LaTeXML::Core::Gullet->new(%options),
    boxing => [], token_stack => [] }, $class; }

#**********************************************************************
# Initialize various parameters, preload, etc.
sub initialize {
  my ($self) = @_;
  $$self{boxing}      = [];
  $$self{token_stack} = [];
  $$self{progress}    = 0;
  $STATE->assignValue(BOUND_MODE        => 'vertical',       'global');
  $STATE->assignValue(MODE              => 'vertical',       'global');
  $STATE->assignValue(IN_MATH           => 0,                'global');
  $STATE->assignValue(PRESERVE_NEWLINES => 1,                'global');
  $STATE->assignValue(afterGroup        => [],               'global');
  $STATE->assignValue(afterAssignment   => undef,            'global');
  $STATE->assignValue(groupInitiator    => 'Initialization', 'global');
  # Setup default fonts.
  $STATE->assignValue(font     => LaTeXML::Common::Font->textDefault(), 'global');
  $STATE->assignValue(mathfont => LaTeXML::Common::Font->mathDefault(), 'global');
  return; }

our $DIGESTION_PROGRESS_QUANTUM = 30000;

#**********************************************************************
sub getGullet {
  my ($self) = @_;
  return $$self{gullet}; }

sub getLocator {
  my ($self) = @_;
  return $$self{gullet}->getLocator; }

sub getBoxingLevel {
  my ($self) = @_;
  return scalar(@{ $$self{boxing} }); }

# ScriptLevel is similar to boxing level, but relative to current Math mode's level
# This is used for the scriptpos attribute to recognize overlapping sccripts.
# Making it relative to the math's level avoids unnecessary changes
sub getScriptLevel {
  my ($self) = @_;
  my $boxlevel = scalar(@{ $$self{boxing} });
  if (my $prevlevel = $STATE->lookupValue('script_base_level')) {
    return $boxlevel - $prevlevel + 1; }
  else {
    return $boxlevel; } }

#**********************************************************************
# Digestion
#**********************************************************************
# NOTE: Worry about whether the $autoflush thing is right?
# It puts a lot of cruft in Gullet; Should we just create a new Gullet?

sub digestNextBody {
  my ($self, $terminal) = @_;
  no warnings 'recursion';
  my $startloc  = getLocator($self);
  my $initdepth = scalar(@{ $$self{boxing} });
  my $token;
  local @LaTeXML::LIST = ();
  my $alignment = $STATE->lookupValue('Alignment');
  my @aug       = ();

  while (defined($token = $$self{gullet}->getPendingComment || $$self{gullet}->readXToken(1))) {
    if ($alignment && scalar(@LaTeXML::LIST) && (Equals($token, T_ALIGN) ||
        Equals($token, T_CS('\cr')) || Equals($token, T_CS('\lx@hidden@cr')) ||
        Equals($token, T_CS('\lx@hidden@crcr')))) {
      # at least \over calls in here without the intent to passing through the alignment.
      # So if we already have some digested boxes available, return them here.
      $$self{gullet}->unread($token);
      return @LaTeXML::LIST; }
    my @r = invokeToken($self, $token);
    push(@LaTeXML::LIST, @r);
    push(@aug, $token, @r);
    last if $terminal and Equals($token, $terminal);
    last if $initdepth > scalar(@{ $$self{boxing} }); }    # if we've closed the initial mode.
  Warn('expected', $terminal, $self, "body should have ended with '" . ToString($terminal) . "'",
    "current body started at " . ToString($startloc),
    "Got " . join("\n -- ", map { Stringify($_) } @aug))
    if $terminal && !Equals($token, $terminal);
  push(@LaTeXML::LIST, Box()) unless $token;               # Dummy `trailer' if none explicit.
  return @LaTeXML::LIST; }

# Digest a list of tokens independent from any current Gullet.
# Typically used to digest arguments to primitives or constructors.
# Returns a List containing the digested material.
sub digest {
  my ($self, $tokens) = @_;
  no warnings 'recursion';
  return unless defined $tokens;
  return
    $$self{gullet}->readingFromMouth(LaTeXML::Core::Mouth->new(), sub {
      my ($gullet) = @_;
      $gullet->unread($tokens);
      $STATE->clearPrefixes;    # prefixes shouldn't apply here.
      my $mode      = $STATE->lookupValue('MODE');
      my $ismath    = $STATE->lookupValue('IN_MATH');
      my $initdepth = scalar(@{ $$self{boxing} });
      local @LaTeXML::LIST = ();
      while (defined(my $token =
            $$self{gullet}->getPendingComment || $$self{gullet}->readXToken(1))) {
        push(@LaTeXML::LIST, invokeToken($self, $token));
        last if $initdepth > scalar(@{ $$self{boxing} }); }    # if we've closed the initial mode.
      List(@LaTeXML::LIST, mode => $mode);
    }); }

# Invoke a token;
# If it is a primitive or constructor, the definition will be invoked,
# possibly arguments will be parsed from the Gullet.
# Otherwise, the token is simply digested: turned into an appropriate box.
# Returns a list of boxes/whatsits.
my $MAXSTACK = 200;    # [CONSTANT]

# Overly complex, but want to avoid recursion/stack
our @CATCODE_ABSORBABLE = (    # [CONSTANT]
  0, 0, 0, 0,
  0, 0, 0, 0,
  0, 0, 1, 1,
  1, 0, 1, 0,
  0, 0, 0, 0);

sub invokeToken {
  no warnings 'recursion';
  my ($self, $token) = @_;
INVOKE:
  ProgressStep() if ($$self{progress}++ % $DIGESTION_PROGRESS_QUANTUM) == 0;
  push(@{ $$self{token_stack} }, $token);
  if (scalar(@{ $$self{token_stack} }) > $MAXSTACK) {
    Fatal('internal', '<recursion>', $self,
      "Excessive recursion(?): ",
      "Tokens on stack: " . join(', ', map { ToString($_) } @{ $$self{token_stack} })); }
  local $LaTeXML::CURRENT_TOKEN = $token;
  my @result  = ();
  my $meaning = $STATE->lookupDigestableDefinition($token);

  if (!$meaning) {
    @result = invokeToken_undefined($self, $token); }
  elsif ($meaning->isaToken) {    # Common case
    my $cc = $meaning->getCatcode;
    if ($cc == CC_CS) {
      @result = invokeToken_undefined($self, $token); }
    elsif ($CATCODE_ABSORBABLE[$cc]) {
      @result = invokeToken_simple($self, $token, $meaning); }
    else {
      # Special error guard for the align char "&":
      # Locally deactivate to avoid a flurry of errors in the same table.
      # Alert the end user once per table, allowing longer documents to not
      # hit 100 errors too quickly.
      $STATE->assignMeaning($token,
        $STATE->lookupMeaning(T_CS('\relax')), 'local')
        if Equals($token, T_ALIGN);
      Error('misdefined', $token, $self,
        "The token " . Stringify($token) . " should never reach Stomach!");
      @result = invokeToken_simple($self, $token, $meaning); } }
  # A math-active character will (typically) be a macro,
  # but it isn't expanded in the gullet, but later when digesting, in math mode (? I think)
  elsif ($meaning->isExpandable) {
    my $gullet = $$self{gullet};
    $gullet->unread($meaning->invoke($gullet));
    $token = $gullet->readXToken();    # replace the token by it's expansion!!!
    pop(@{ $$self{token_stack} });
    goto INVOKE if $token; }
  elsif ($meaning->isaDefinition) {    # Otherwise, a normal primitive or constructor
    @result = $meaning->invoke($self);
    $STATE->clearPrefixes unless $meaning->isPrefix; }    # Clear prefixes unless we just set one.
  else {
    Error('misdefined', $meaning, $self,
      "The object " . Stringify($meaning) . " should never reach Stomach!");
    @result = (makeMisdefinedError($meaning)); }
  if ((scalar(@result) == 1) && (!defined $result[0])) {
    @result = (); }                                       # Just paper over the obvious thing.
  if (my @bad = grep { (!blessed $_) || (!$_->isaBox) } @result) {
    Error('misdefined', $token, $self,
      "Execution yielded non boxes",
      "Returned " . join(',', map { "'" . Stringify($_) . "'" } @bad));
    @result = (makeMisdefinedError(@result)); }
  pop(@{ $$self{token_stack} });
  return @result; }

sub makeMisdefinedError {
  my (@objects) = @_;
  return LaTeXML::Core::Whatsit->new($STATE->lookupDefinition(T_CS('\lx@ERROR')),
    ['misdefined', join('', map { ToString($_); } @objects)],
    font => $STATE->lookupValue('font'),
  ); }

sub invokeToken_undefined {
  my ($self, $token) = @_;
  $STATE->generateErrorStub($self, $token);
  $$self{gullet}->unread($token);    # Retry
  return; }

sub invokeToken_simple {
  my ($self, $token, $meaning) = @_;
  my $cc   = $meaning->getCatcode;
  my $font = $STATE->lookupValue('font');
  if ($cc == CC_SPACE) {
    $STATE->clearPrefixes;                   # prefixes shouldn't apply here.
    if($STATE->lookupValue('MODE') =~ /(?:math|vertical)$/) {
      return (); }
    else {
      enterHorizontal($self);
      return Box($meaning->toString, $font, $$self{gullet}->getLocator, $meaning); } }
  elsif ($cc == CC_COMMENT) {                # Note: Comments need char decoding as well!
    my $comment = LaTeXML::Package::FontDecodeString($meaning->toString, undef, 1);
    # However, spaces normally would have be digested away as positioning...
    my $badspace = pack('U', 0xA0) . "\x{0335}";    # This is at space's pos in OT1
    $comment =~ s/\Q$badspace\E/ /g;
    return LaTeXML::Core::Comment->new($comment); }
  else {
    $STATE->clearPrefixes;                          # prefixes shouldn't apply here.
    if (my $mathcode = $STATE->lookupValue('IN_MATH')
      && $STATE->lookupMathcode($meaning->toString)) {
      my ($glyph, $f, $reversion, %props) = LaTeXML::Package::decodeMathChar($mathcode, $meaning);
      return Box($glyph, $f, undef, $reversion, %props); }
    else {
      enterHorizontal($self);
      return Box(LaTeXML::Package::FontDecodeString($meaning->toString, undef, 1),
        undef, undef, $meaning); } } }

# Regurgitate: steal the previously digested boxes from the current level.
sub regurgitate {
  my ($self) = @_;
  my @stuff = @LaTeXML::LIST;
  @LaTeXML::LIST = ();
  return @stuff; }

#**********************************************************************
# Maintaining State.
#**********************************************************************
# State changes that the Stomach needs to moderate and know about (?)

#======================================================================
# Dealing with TeX's bindings & grouping.
# Note that lookups happen more often than bgroup/egroup (which open/close frames).

sub pushStackFrame {
  my ($self, $nobox) = @_;
  $STATE->pushFrame;
  $STATE->assignValue(beforeAfterGroup      => [],                      'local');  # ALWAYS bind this!
  $STATE->assignValue(afterGroup            => [],                      'local');  # ALWAYS bind this!
  $STATE->assignValue(afterAssignment       => undef,                   'local');  # ALWAYS bind this!
  $STATE->assignValue(groupNonBoxing        => $nobox,                  'local');  # ALWAYS bind this!
  $STATE->assignValue(groupInitiator        => $LaTeXML::CURRENT_TOKEN, 'local');
  $STATE->assignValue(groupInitiatorLocator => getLocator($self),       'local');
  push(@{ $$self{boxing} }, $LaTeXML::CURRENT_TOKEN) unless $nobox;    # For begingroup/endgroup
  return; }

sub popStackFrame {
  my ($self, $nobox) = @_;
  if (my $beforeafter = $STATE->lookupValue('beforeAfterGroup')) {
    if (@$beforeafter) {
      my @result = map { $_->beDigested($self) } @$beforeafter;
      if (my ($x) = grep { !$_->isaBox } @result) {
        Error('misdefined', $x, $self, "Expected a Box|List|Whatsit, but got '" . Stringify($x) . "'");
        @result = (makeMisdefinedError(@result)); }
      push(@LaTeXML::LIST, @result); } }
  my $after = $STATE->lookupValue('afterGroup');
  $STATE->popFrame;
  pop(@{ $$self{boxing} }) unless $nobox;    # For begingroup/endgroup
  $$self{gullet}->unread(@$after) if $after;
  return; }

sub currentFrameMessage {
  my ($self) = @_;
  return "current frame is "
    . ($STATE->isValueBound('MODE', 0)       # SET mode in CURRENT frame ?
    ? "mode-switch to " . $STATE->lookupValue('MODE')
    : ($STATE->lookupValue('groupNonBoxing')    # Current frame is a non-boxing group?
      ? "non-boxing" : "boxing") . " group")
    . " due to " . Stringify($STATE->lookupValue('groupInitiator'))
    . " " . ToString($STATE->lookupValue('groupInitiatorLocator')); }

#======================================================================
# Grouping pushes a new stack frame for binding definitions, etc.
#======================================================================
# Originally, we only treated math vs text "modes", which are correlated
# to grouping (somehow). But we'll gradually need to incorporate all
# the horizontal/vertical modes, which are NOT correlated to grouping,
# although they do operate on a stack.
# So, we should NOT generate errors when the grouping clashes with modes
# (until we can get it properly sorted).

# if $nobox is true, inhibit incrementing the boxingLevel
sub bgroup {
  my ($self) = @_;
  pushStackFrame($self, 0);
  return; }

sub egroup {
  my ($self) = @_;
  if (    ##$STATE->isValueBound('MODE', 0) ||    # Last stack frame was a mode switch!?!?!
    $STATE->lookupValue('groupNonBoxing')) {    # or group was opened with \begingroup
    Error('unexpected', $LaTeXML::CURRENT_TOKEN, $self, "Attempt to close boxing group",
      currentFrameMessage($self)); }
  else {                                        # Don't pop if there's an error; maybe we'll recover?
    popStackFrame($self, 0); }
  return; }

sub begingroup {
  my ($self) = @_;
  pushStackFrame($self, 1);
  return; }

sub endgroup {
  my ($self) = @_;
  if (    ##$STATE->isValueBound('MODE', 0) ||    # Last stack frame was a mode switch!?!?!
    !$STATE->lookupValue('groupNonBoxing')) {    # or group was opened with \bgroup
    Error('unexpected', $LaTeXML::CURRENT_TOKEN, $self, "Attempt to close non-boxing group",
      currentFrameMessage($self)); }
  else {                                         # Don't pop if there's an error; maybe we'll recover?
    popStackFrame($self, 1); }
  return; }

#======================================================================
# Mode (minimal so far; math vs text)
# Could (should?) be taken up by Stomach by building horizontal, vertical or math lists ?
# Modes describe how TeX assembles boxes being Box, List (of boxes) & Whatsits into pages
# All modes except horizontal are bound in State and explicitly begun and ended using
# $stomach->(begin|end)Mode; which also effect grouping.
# The modes are:
#  vertical : a vertical stack of boxes, like block. The initial mode of TeX.
#     It is a bound mode, but is never entered explicitly.
#     It can be resumed from horizontal mode by $stomach->leaveHorizontal
#  internal_vertical : Also a bound vertical mode, specifically set by \vbox,
#     and should normally be set for most vertically laid out blocks.
#     It can be resumed from horizontal mode by $stomach->leaveHorizontal
#    (probably indistinguishable from vertical in LaTeXML. Theoretically, it does not
#     allow page breaks and may affect timing of \insert?)
#  horizontal : essentially paragraph mode, allowing for line-breaks.
#     It is NOT a bound mode, but is switched-to by non-vertical material digested
#     while in a vertical mode ($stomach->enterHorizontal). If vertical material
#     is encountered while in horizontal mode, $stomach->leaveHorizontal returns
#     to vertical mode.
#     Generally should get a width being the current pagewidth.
#  restricted_horizontal : running horizontal text, without line-breaks.
#     This is a bound mode set by \hbox.
#     It is the default mode for digesting Whatsit arguments, although they
#     may be absorbed into paragraphs where line-breaks occur.
#  inline_math : math within a horizontal mode. A bound mode.
#  display_math : math within a vertical mode. A bound mode.
#     Should be illegal in restricted_horizontal mode;
#     Should leaveHorizontal if in horizontal mode.
#----------------------------------------------------------------------
# These are the only modes that you can beginMode|endMode, and must be entered that way.
our %bindable_mode = (
    text                  => 'restricted_horizontal',
    restricted_horizontal => 'restricted_horizontal',
    vertical              => 'internal_vertical',
    internal_vertical     => 'internal_vertical',
    inline_math           => 'inline_math',
    display_math          => 'display_math');

# Switch to horizontal mode, w/o stacking the mode
# Can really only switch to horizontal mode from vertical|internal_vertical,
# so no math, font, etc changes are needed.
sub enterHorizontal {
  my($self) = @_;
  my $mode  = $STATE->lookupValue('MODE');
  if($mode =~ /vertical$/){
    Debug("MODE entering $mode => horizontal, due to ".Stringify($LaTeXML::CURRENT_TOKEN))
        if $LaTeXML::DEBUG{modes};
    $STATE->assignValue(MODE => 'horizontal', 'inplace'); } # SAME frame as BOUND_MODE!
  elsif (($mode =~ /horizontal$/) || ($mode =~ /math$/)) { } # ignorable?
  else {
    Warn('unexpected',$mode,$self,
      "Cannot switch to horizontal mode from $mode"); }
  return; }

# Resume vertical mode, if in horizontal mode, by executing \par, in TeX-like fashion.
sub leaveHorizontal {
  my($self) = @_;
  my $mode  = $STATE->lookupValue('MODE');
  my $bound = $STATE->lookupValue('BOUND_MODE');
  # This needs to be an invisible, and slightly gentler, \par (see \lx@normal@par)
  # BUT still allow user defined \par !
  if (($mode eq 'horizontal') && ($bound =~ /vertical$/)) {
    local $LaTeXML::INTERNAL_PAR = 1;
    push(@LaTeXML::LIST, $self->invokeToken(T_CS('\par'))); }
  return; }

# Repack recently digested horizontal items into single horizontal List.
# Note that TeX would have done paragraph line-breaking, resulting in essentially
# a vertical list.
sub repackHorizontal {
  my($self)=@_;
  my @para = ();
  my $item;
  my $mode;
  my $keep = 0;
  while(@LaTeXML::LIST
        && ($item = $LaTeXML::LIST[-1])
        && (($mode = ($item->getProperty('mode')||'horizontal'))
            =~ /^(?:horizontal|restricted_horizontal|inline_math)$/)) {
    # if ONLY horizontal mode spaces, we can prune them; it just makes an empty ltx:p
    $keep = 1 if ($mode ne 'horizontal') || ! $item->getProperty('isSpace');
    unshift(@para,pop(@LaTeXML::LIST)); }
  push(@LaTeXML::LIST, List(@para, mode=>'horizontal')) if $keep;
  return; }

# Resume vertical mode, internal form: reset mode, and repacks recently
# digested horizontal items. This is useful within argument digestion, eg.
sub leaveHorizontal_internal {
  my($self) = @_;
  my $mode  = $STATE->lookupValue('MODE');
  my $bound = $STATE->lookupValue('BOUND_MODE');
  # This needs to be an invisible, and slightly gentler, \par (see \lx@normal@par)
  # BUT still allow user defined \par !
  if (($mode eq 'horizontal') && ($bound =~ /vertical$/)) {
    Debug("MODE leaving $mode => $bound, due to ".Stringify($LaTeXML::CURRENT_TOKEN))
        if $LaTeXML::DEBUG{modes};
    repackHorizontal($self);
    $STATE->assignValue(MODE => $bound, 'inplace'); }
 return; }

sub beginMode {
  my ($self, $umode) = @_;
  if (my $mode = $bindable_mode{$umode}) {
    my $prevmode = $STATE->lookupValue('BOUND_MODE');
    my $ismath   = $mode =~ /math$/;
    my $wasmath  = $prevmode =~ /math$/;
    pushStackFrame($self);    # Effectively bgroup
    $STATE->assignValue(BOUND_MODE => $mode,   'local'); # New value within this frame!
    $STATE->assignValue(MODE       => $mode,   'local');
    $STATE->assignValue(IN_MATH    => $ismath, 'local');
    Debug("MODE binding $prevmode => $mode, due to ".Stringify($LaTeXML::CURRENT_TOKEN))
        if $LaTeXML::DEBUG{modes};
    my $curfont = $STATE->lookupValue('font');
    if    ($mode eq $prevmode) { }
    elsif ($ismath) {
      # When entering math mode, we set the font to the default math font,
      # and save the text font for any embedded text.
      $STATE->assignValue(savedfont         => $curfont, 'local');
      $STATE->assignValue(script_base_level => scalar(@{ $$self{boxing} }));    # See getScriptLevel
      my $isdisplay = $mode =~ /^display/;
      my $mathfont  = $STATE->lookupValue('mathfont')->merge(
        color     => $curfont->getColor, background => $curfont->getBackground,
        size      => $curfont->getSize,
        mathstyle => ($isdisplay ? 'display' : 'text'));
      $STATE->assignValue(font              => $mathfont, 'local');
      $STATE->assignValue(initial_math_font => $mathfont, 'local');
      $STATE->assignValue(fontfamily        => -1,        'local');
      my $every = ($isdisplay ? T_CS('\everydisplay') : T_CS('\everymath'));
      my $ereg  = $STATE->lookupDefinition($every);
      if (my $toks = $ereg && $ereg->isRegister && $ereg->valueOf()) {
        $self->getGullet->unread($toks); } }
    elsif($wasmath) {
      # When entering text mode, we should set the font to the text font in use before the math
      # but inherit color and size
      $STATE->assignValue(font => $STATE->lookupValue('savedfont')->merge(
          color => $curfont->getColor, background => $curfont->getBackground,
          size  => $curfont->getSize), 'local'); }
  }
  else {
    Warn('unexpected',$mode,$self, "Cannot enter $mode mode"); }
  return; }

sub endMode {
  my ($self, $umode) = @_;
  if (my $mode = $bindable_mode{$umode}) {
    if ((!$STATE->isValueBound('BOUND_MODE', 0))    # Last stack frame was NOT a mode switch!?!?!
      || ($STATE->lookupValue('BOUND_MODE') ne $mode)) {    # Or was a mode switch to a different mode
      # Don't pop if there's an error; maybe we'll recover?
      Error('unexpected', $LaTeXML::CURRENT_TOKEN, $self, "Attempt to end mode $mode",
        currentFrameMessage($self)); }
    else {
      leaveHorizontal_internal($self) if $mode =~ /vertical$/; # nopar version!
      popStackFrame($self);        # Effectively egroup.
      Debug("MODE unbinding $mode => ".$STATE->lookupValue('MODE').", due to ".Stringify($LaTeXML::CURRENT_TOKEN))
          if $LaTeXML::DEBUG{modes};
    }}
  else {
    Warn('unexpected',$mode,$self, "Cannot end $mode mode"); }
  return; }

#**********************************************************************
1;

__END__

=pod

=head1 NAME

C<LaTeXML::Core::Stomach> - digests tokens into boxes, lists, etc.

=head1 DESCRIPTION

C<LaTeXML::Core::Stomach> digests tokens read from a L<LaTeXML::Core::Gullet>
(they will have already been expanded).

It extends L<LaTeXML::Common::Object>.

There are basically four cases when digesting a L<LaTeXML::Core::Token>:

=over 4

=item A plain character

is simply converted to a L<LaTeXML::Core::Box>
recording the current L<LaTeXML::Common::Font>.

=item A primitive

If a control sequence represents L<LaTeXML::Core::Definition::Primitive>, the primitive is invoked, executing its
stored subroutine.  This is typically done for side effect (changing the state in the L<LaTeXML::Core::State>),
although they may also contribute digested material.
As with macros, any arguments to the primitive are read from the L<LaTeXML::Core::Gullet>.

=item Grouping (or environment bodies)

are collected into a L<LaTeXML::Core::List>.

=item Constructors

A special class of control sequence, called a L<LaTeXML::Core::Definition::Constructor> produces a
L<LaTeXML::Core::Whatsit> which remembers the control sequence and arguments that
created it, and defines its own translation into C<XML> elements, attributes and data.
Arguments to a constructor are read from the gullet and also digested.

=back

=head2 Digestion

=over 4

=item C<< $list = $stomach->digestNextBody; >>

Return the digested L<LaTeXML::Core::List> after reading and digesting a `body'
from the its Gullet.  The body extends until the current
level of boxing or environment is closed.

=item C<< $list = $stomach->digest($tokens); >>

Return the L<LaTeXML::Core::List> resuting from digesting the given tokens.
This is typically used to digest arguments to primitives or
constructors.

=item C<< @boxes = $stomach->invokeToken($token); >>

Invoke the given (expanded) token.  If it corresponds to a
Primitive or Constructor, the definition will be invoked,
reading any needed arguments fromt he current input source.
Otherwise, the token will be digested.
A List of Box's, Lists, Whatsit's is returned.

=item C<< @boxes = $stomach->regurgitate; >>

Removes and returns a list of the boxes already digested
at the current level.  This peculiar beast is used
by things like \choose (which is a Primitive in TeX, but
a Constructor in LaTeXML).

=back

=head2 Grouping

=over 4

=item C<< $stomach->bgroup; >>

Begin a new level of binding by pushing a new stack frame,
and a new level of boxing the digested output.

=item C<< $stomach->egroup; >>

End a level of binding by popping the last stack frame,
undoing whatever bindings appeared there, and also
decrementing the level of boxing.

=item C<< $stomach->begingroup; >>

Begin a new level of binding by pushing a new stack frame.

=item C<< $stomach->endgroup; >>

End a level of binding by popping the last stack frame,
undoing whatever bindings appeared there.

=back

=head2 Modes

=over 4

=item C<< $stomach->beginMode($mode); >>

Begin processing in C<$mode>; one of 'text', 'display-math' or 'inline-math'.
This also begins a new level of grouping and switches to a font
appropriate for the mode.

=item C<< $stomach->endMode($mode); >>

End processing in C<$mode>; an error is signalled if C<$stomach> is not
currently in C<$mode>.  This also ends a level of grouping.

=back

=head1 AUTHOR

Bruce Miller <bruce.miller@nist.gov>

=head1 COPYRIGHT

Public domain software, produced as part of work done by the
United States Government & not subject to copyright in the US.

=cut
