//= require jquery
//= require jquery_ujs
//= require bootstrap
//= require jquery-ui/effect.all
//= require jquery-tablesorter
//= require jquery.Jcrop
//= require hoverIntent
//= require bootstrap-hover-dropdown
//= require jquery.tokeninput
//= require_tree .

//Don't load anything before the document is ready.
$(document).ready(function() {

    // When any form with the class "onchange_submit" is altered, the form gets submitted.
    $('.onchange_submit').change(function() { $
        (this).submit();
    });

    //Anything of class "trigger" will cause the next thing to be toggled. (Use if you have a header directly above the thing it toggles)
    //Also, the trigger will gain the class "triggered" in case any styling needs to be changed on the trigger
	$(".trigger").click(function(){
		$(this).toggleClass("triggered").next().slideToggle('fast');
		event.preventDefault(); //don't actually follow the link/action (even '#' goes to top of page in some cases)
	});

    //Anything of class "trigger-<id>" will cause something of class "toggle-<id>" with the same <id> to be toggled
    //Also, the trigger will gain the class "triggered" in case any styling needs to be changed on the trigger
	$("[class*=trigger-]").click(function(){
		$(".toggle-"+$(this).toggleClass("triggered").attr("class").match(/trigger-((\w|-)+)\b/)[1]).slideToggle('fast');
		event.preventDefault(); //don't actually follow the link/action (even '#' goes to top of page in some cases)
	});

    //Also, make all triggers links
    $("[class*=trigger]").each(function() {
      $(this).html("<a href='#'>"+$(this).text()+"</a>");
    });


    $("#modal").on("hidden.bs.modal", function(){
      // force reloading remote content
      $(this).removeData('bs.modal');
    });

    $("#modal").on("click","#submit-modal", function(){
      var button = $(this);
      var submit_text = button.text();
      var submitting_text = button.data("submitting");
      var form = $(this).closest('div.modal-content').find('form');
      button.prop("disabled",true).text(submitting_text);
      form.submit();
      $(document).ajaxComplete(function(){
        button.text(submit_text).prop("disabled",false);
      });
    })

    // Tooltips
    var elems_for_tooltip = [$(".notice a.close"), $(".notice #edit")];
    $(elems_for_tooltip).each(function(){
      $(this).tooltip({
        container: 'body'
      });
    });

});
