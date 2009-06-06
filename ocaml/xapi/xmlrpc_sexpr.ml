(** Functions for converting between xml-rpc and a more
    compact representation based on s-expressions.
    v1 marcusg@eu.citrix.com
*)

open Xml
open XMLRPC
open SExpr


let rec trim str =
	let len=String.length str in
	if len=0 then str
	else match (str.[0],str.[len-1]) with
		| ((' '|'\t'|'\n'),_) -> trim (String.sub str 1 (len-1))
		| (_,(' '|'\t'|'\n')) -> trim (String.sub str 0 (len-2))
		| _ -> str

(** Accepts an xml-rpc tree of type xml.xml
    with contents <tag> [child1] [child2] ... [childn] </tag>
    where: - tag is an xml tag.
           - child is an xml tag or a pcdata.
    and converts it to an sexpr tree of type SExpr.t
    with contents (tag child1 child2 ... childn)
    where: - tag is an SExpr.String
           - child is an SExpr.t (String or Node)
    exception: 
           - 'member' tags are not in sexpr because they 
             are basically redundant information inside struct children.
    security notes: 
           1. there is no verification that the incoming xml-rpc tree
              conforms to the xml-rpc specification. an incorrect xml-rpc tree
              might result in an unexpected sexpr mapping. therefore, this
              function should not be used to process unsanitized/untrusted xml-rpc trees.
*)
let xmlrpc_to_sexpr (root:xml) = 

	let rec visit (h:int) (xml_lt:xml list) = match (h, xml_lt) with
		| h, [] -> []
		| h, (PCData text)::_ ->
		let text = trim text in
		SExpr.String text::[] 	 

		(* empty <value>s have default value '' *)
		| h,((Element ("value", _, []))::siblings) ->
		(SExpr.String "")::(visit (h) siblings)

		(* <data>,<value>,<name> tags: ignore them and go to children *)
		| h,((Element ("data", _, children))::siblings)
		| h,((Element ("value", _, children))::siblings)
		| h,((Element ("name", _, children))::siblings) ->
		(visit (h+1) children)@(visit (h) siblings)

		(* <member> tags *)
		| h,((Element ("member", _, children))::siblings) -> 
			let (mychildren:SExpr.t list) = visit (h+1) children in
			let anode = (SExpr.Node (mychildren)) in
			let (mysiblings:SExpr.t list) = visit (h) siblings in
			if (List.length mychildren) = 2 then (*name & value?*)
				begin match (List.nth mychildren 0) with
				|(SExpr.String name) -> (*is name a string?*) 
					anode::mysiblings (*then add member anode*)
				|_ -> 
					mysiblings (*ignore incorrect member*)
				end
			else mysiblings (*ignore incorrect member*)

		(* any other element *)
		| h,((Element (tag, _, children))::siblings) -> 
			let tag = trim tag in
			let mytag = (SExpr.String tag) in
			let (mychildren:SExpr.t list) = visit (h+1) children in
			let anode = (SExpr.Node (mytag::mychildren)) in
			let (mysiblings:SExpr.t list) = visit (h) siblings in
				anode::mysiblings
	in 
		List.hd (visit 0 (root::[]))

(** Accepts a tree of s-expressions of type SExpr.t
    with contents (tag child1 child2 ... childn)
    where: - tag is an SExpr.String
           - child is an SExpr.t (String or Node)
    and converts it to an xml-rpc tree of type xml.xml
    with contents <tag> [child1] [child2] ... [childn] </tag>
    where: - tag is an xml tag.
           - child is an xml tag or a pcdata.
    exception: 
           - 'member' tags are not in sexpr because they 
             are redundant information inside struct children.
    security notes: 
           1. there is no verification that the incoming sexpr trees
              conforms to the output of xmlrpc_to_sexpr. an incorrect sexpr tree
              might result in an unexpected xml-rpc mapping. therefore, this
              function should not be used to process unsanitized/untrusted sexpr trees.
*)
let sexpr_to_xmlrpc (root:SExpr.t) = 

	let encase_with (container:string) (el:xml) = 
		(Element (container,[],el::[])) 
	in
	let is_not_empty_tag (el:xml) = match (el) with
		| (Element ("",_,_)) -> false
		| _ -> true
	in
	let rec visit (h:int) (parent:SExpr.t) (sexpr:SExpr.t) = match (h, parent, sexpr) with

		(* sexpr representing a struct with member tags *)
		| h, (SExpr.Node (SExpr.String "struct"::_)), (SExpr.Node (SExpr.String name:: avalue ::_))->
			begin match (avalue) with
				|SExpr.String ""  ->
					(Element ("member",[],Element ("name",[],PCData name::[])::Element ("value",[],[])::[])) 
				|SExpr.String value  ->
					(Element ("member",[],Element ("name",[],PCData name::[])::Element ("value",[],PCData value::[])::[])) 
				|SExpr.Node _ as somenode -> 
					(Element ("member",[],Element ("name",[],PCData name::[])::Element ("value",[],(visit (h+1) (SExpr.String "member") (somenode))::[])::[])) 
				|_ -> (Element ("WRONG_SEXPR_MEMBER",[],[]))     
			end

		(* member tag without values - wrong format - defaults to empty value *)
		| h, (SExpr.Node (SExpr.String "struct"::_)), (SExpr.Node (SExpr.String name:: []))->
			(Element ("member",[],Element ("name",[],PCData name::[])::Element ("value",[],[])::[]))

		(* sexpr representing array tags *)
		| h, _, (SExpr.Node (SExpr.String "array"::values)) ->
			let xmlvalues =  (List.map (visit (h+1) sexpr) values) in
				(Element ("array",[],Element ("data",[],List.map (encase_with "value") xmlvalues)::[]))

		(* sexpr representing any other tag with children *)
		| h, _, (SExpr.Node (SExpr.String tag::atail)) -> 
			let xmlvalues =  (List.map (visit (h+1) sexpr) atail) in
			let xml_noemptytags = List.filter (is_not_empty_tag) xmlvalues in 
				(Element (tag, [], xml_noemptytags))

		(* sexpr representing any other tag with no children *)
		| h, _, (SExpr.Node (SExpr.String tag::[])) -> 
			(Element (tag, [], []))

		(* sexpr representing a pcdata *)
		| h, _, (SExpr.String s) -> 
			(PCData s)

		(* sexpr representing a nameless tag *)
		| h, _, (SExpr.Node []) -> 
			(Element ("EMPTY_SEXPR",[],[]))

		(* otherwise, we reached a senseless sexpr *)
		| _ -> (Element ("WRONG_SEXPR",[],[]))
	in 
		(encase_with "value" (visit 0 (SExpr.Node []) root))

(** helper function that maps between sexpr strings and xml-rpc trees *)
let sexpr_str_to_xmlrpc (sexpr_str:string) =
	let sroot1 = Sexpr.of_string sexpr_str in
	let xroot1 = sexpr_to_xmlrpc sroot1 in
	(xroot1)

(** helper function that maps between xml-rpc trees and sexpr strings *)
let xmlrpc_to_sexpr_str xml=
	let sroot1 = xmlrpc_to_sexpr xml in
	SExpr.string_of sroot1

